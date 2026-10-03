#!/usr/bin/env bash
# 云主机（算力自由）环境自检 + 依赖安装 + 素材准备。
#
# 幂等，可重复跑。跑完后生成 cloud/env.sh，run_batch.sh 会 source 它。
#
# 用法：
#   deploy/cloud/bootstrap.sh --dataset /root/gpufree-data/coco
#   deploy/cloud/bootstrap.sh --dataset ... --data-dir /root/gpufree-data --with-convert
#
# 选项：
#   --dataset PATH   训练集**根目录**（ImageFolder 语义：它的下一层才是图片，
#                    例如 .../coco 而图片在 .../coco/train2014/）
#   --data-dir PATH  持久化目录，默认 /root/gpufree-data（队友脚本 para.py 里就是这个路径）
#   --with-convert   额外装转换栈（TF/onnx/onnx2tf）。**装 tensorflow-cpu，不装 GPU 版**，
#                    避免和云镜像里的 CUDA torch 抢 cuDNN。
#   --no-mirror      不用清华源，走默认 PyPI
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$(cd "$HERE/.." && pwd)"
DATA_DIR="/root/gpufree-data"
DATASET=""
WITH_CONVERT=0
PIP_INDEX="-i https://pypi.tuna.tsinghua.edu.cn/simple"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dataset)     DATASET="$2"; shift 2 ;;
        --data-dir)    DATA_DIR="$2"; shift 2 ;;
        --with-convert) WITH_CONVERT=1; shift ;;
        --no-mirror)   PIP_INDEX=""; shift ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

PY="${PY:-python3}"
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠  $*"; }
bad()  { echo "  ❌ $*"; }

echo "==> 1/6 Python 与 GPU"
$PY -V
$PY - <<'PYCODE' || true
import shutil, sys
try:
    import torch
    print(f"  torch {torch.__version__}  cuda_available={torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"  GPU: {torch.cuda.get_device_name(0)}  "
              f"capability={torch.cuda.get_device_capability(0)}")
        print(f"  显存 {torch.cuda.get_device_properties(0).total_memory/2**30:.1f} GiB")
    else:
        print("  ⚠ CUDA 不可用：训练会退回 CPU（会很慢），检查驱动/镜像")
except ImportError:
    print("  ⚠ 未安装 torch")
PYCODE
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total,driver_version \
    --format=csv,noheader | sed 's/^/  /' || warn "没有 nvidia-smi"

echo "==> 2/6 训练依赖"
MISSING=$($PY - <<'PYCODE'
mods = []
for m in ("torch", "torchvision", "numpy", "PIL", "scipy", "tqdm"):
    try:
        __import__(m)
    except ImportError:
        mods.append({"PIL": "pillow"}.get(m, m))
print(" ".join(mods))
PYCODE
)
if [[ -n "$MISSING" ]]; then
    echo "  缺失: $MISSING"
    # 注意：绝不在这里重装 torch/torchvision —— 云镜像自带的是 CUDA 版，
    # 从 PyPI 装会拉成 CUDA 12/13 版本，和镜像驱动不匹配。
    APT=$(echo "$MISSING" | tr ' ' '\n' | grep -vE '^(torch|torchvision)$' | tr '\n' ' ')
    if [[ -n "${APT// /}" ]]; then
        $PY -m pip install $PIP_INDEX $APT
    fi
    if echo "$MISSING" | grep -q torch; then
        warn "缺 torch/torchvision。请用镜像自带版本，或按 https://pytorch.org 的对应 CUDA 版本安装；"
        warn "不要直接 pip install torch（会装成和驱动不匹配的 CUDA 构建）。"
    fi
else
    ok "torch/torchvision/numpy/pillow/scipy/tqdm 都在"
fi

echo "==> 3/6 空格检查（VGG16 权重 528 MB + 数据集 + checkpoint）"
df -h "$DATA_DIR" 2>/dev/null | tail -1 | sed 's/^/  /' || warn "$DATA_DIR 不存在"
mkdir -p "$DATA_DIR"

echo "==> 4/6 素材（风格图 + 校准图）来自 FinResect/examples@Iris"
EXAMPLES="$DATA_DIR/examples"
if [[ -d "$EXAMPLES/.git" ]]; then
    (cd "$EXAMPLES" && git fetch -q origin Iris && git checkout -q origin/Iris 2>/dev/null || true)
    ok "已更新 $EXAMPLES"
else
    git clone -q -b Iris https://github.com/FinResect/examples.git "$EXAMPLES" \
        && ok "已克隆 $EXAMPLES" || bad "克隆失败（检查网络）"
fi
STYLE="$EXAMPLES/fast_neural_style/images/style-images/one_last_kiss.png"
CALIB="$EXAMPLES/fast_neural_style/images/calib"
[[ -f "$STYLE" ]] && ok "风格图 $STYLE" || bad "找不到风格图 $STYLE"
NCAL=$(ls "$CALIB" 2>/dev/null | wc -l)
[[ "$NCAL" -gt 0 ]] && ok "校准图 $NCAL 张 @ $CALIB" || bad "校准目录为空 $CALIB"

echo "==> 5/6 训练集"
if [[ -z "$DATASET" ]]; then
    warn "没给 --dataset，先跳过"
elif [[ -d "$DATASET" ]]; then
    N=$(find "$DATASET" -maxdepth 2 -type f \( -name '*.jpg' -o -name '*.png' \) 2>/dev/null | wc -l)
    ok "$DATASET（$N 张图）"
    # ImageFolder 要求 dataset 下还要有一层子目录
    SUB=$(find "$DATASET" -mindepth 1 -maxdepth 1 -type d | wc -l)
    if [[ "$SUB" -eq 0 ]]; then
        warn "该目录下没有子文件夹。ImageFolder 需要 dataset/<子目录>/*.jpg，"
        warn "例如 --dataset $DATASET 而图片在 $DATASET/train2014/"
    fi
else
    bad "$DATASET 不存在。COCO train2014 下载：https://cocodataset.org/#download"
    echo "      （13 GB，解压后若是 train2014/*.jpg，则 --dataset 指向其父目录）"
fi

if [[ "$WITH_CONVERT" == "1" ]]; then
    echo "==> 6/6 转换栈（tensorflow-cpu + onnx + onnx2tf）"
    $PY -m pip install $PIP_INDEX \
        "tensorflow-cpu>=2.16" onnx onnxruntime onnx2tf tf_keras pillow numpy scikit-image
    ok "转换栈已装（如果在云上也做量化，run_batch.sh 会用到）"
else
    echo "==> 6/6 跳过转换栈（未给 --with-convert）"
    echo "      转换/量化建议在本地做（deploy/.venv 已配好），云上只训练更省事。"
fi

cat > "$HERE/env.sh" <<EOF
# 由 bootstrap.sh 生成 $(date '+%F %T')，run_batch.sh 会 source
export DEPLOY_ROOT="$DEPLOY"
export DATA_DIR="$DATA_DIR"
export EXAMPLES_DIR="$EXAMPLES"
export STYLE_IMAGE="$STYLE"
export CALIB_DIR="$CALIB"
export DATASET="$DATASET"
export PY="$PY"
export TORCH_HOME="$DATA_DIR/.torch"
EOF
echo
echo "已写出 $HERE/env.sh"
echo "下一步：  deploy/cloud/run_batch.sh --smoke    # 先跑 1 个 epoch 验证链路"
echo "          deploy/cloud/run_batch.sh          # 再跑完整网格"
