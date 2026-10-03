#!/usr/bin/env bash
# 网页端一键：取到代码后，把「准备工作 + 冒烟」一次跑完。
#
# 专为在 JupyterLab / VSCode 网页终端里**粘贴一行**用，不需要 SSH。
#
# 用法（在网页终端里粘贴）：
#   bash /root/gpufree-data/Iris/deploy/cloud/web_quickstart.sh \
#        --dataset /root/gpufree-data/coco
#
#   --dataset 给「ImageFolder 根」（如 .../coco）或「图片目录」（如 .../coco/train2014）
#   都行，脚本会用 dataset_paths.sh 自动识别层数（这两个参数含义相反，别记错了）。
#
# 会做：定位路径 → 环境自检 → 拉风格图/校准图 → 抽子集（给了 --subset 或 COCO 存在时）
#       → 查 GPU → 跑冒烟
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$(cd "$HERE/.." && pwd)"

DATA_DIR="/root/gpufree-data"
DATASET=""
SUBSET_N=10000
DO_SMOKE=1
MIRROR=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dataset)   DATASET="$2"; shift 2 ;;
        --data-dir)  DATA_DIR="$2"; shift 2 ;;
        --subset)    SUBSET_N="$2"; shift 2 ;;
        --no-subset) SUBSET_N=0; shift ;;
        --no-smoke)  DO_SMOKE=0; shift ;;
        --no-mirror) MIRROR=0; shift ;;
        -h|--help)   sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

hr() { printf '\n\033[1m===== %s =====\033[0m\n' "$1"; }

# 先把 --dataset 解析成 (根, 图片目录) 一对（详见 dataset_paths.sh 里的说明）
source "$HERE/dataset_paths.sh"
DS_ROOT=""; DS_IMG_SRC=""; DS_ERR=""
DATASET_OK=0
if [[ -n "$DATASET" ]] && resolve_dataset "$DATASET"; then
    DATASET_OK=1
fi

hr "0/5 定位"
echo "  代码目录: $DEPLOY"
echo "  数据盘  : $DATA_DIR"
if [[ ! -d "$DATA_DIR" ]]; then
    echo "  ⚠ $DATA_DIR 不存在 —— 你确定这是在算力自由的实例里吗？"
    echo "    平台的数据盘固定挂在 /root/gpufree-data，代码应放在这下面。"
fi
df -h "$DATA_DIR" 2>/dev/null | tail -1 | sed 's/^/  /'

hr "1/5 环境自检 + 拉素材"
ARGS=(--data-dir "$DATA_DIR")
# 只把**解析成功**的根写进 env.sh —— 否则 run_batch.sh 会 source 到一个错的 DATASET
[[ "$DATASET_OK" == "1" ]] && ARGS+=(--dataset "$DS_ROOT")
[[ "$MIRROR" == "0" ]] && ARGS+=(--no-mirror)
"$DEPLOY/cloud/bootstrap.sh" "${ARGS[@]}" || echo "  ⚠ bootstrap 有告警，继续"

hr "2/5 准备训练集"
# 冒烟只需要能跑通链路，不需要真数据集。没给 COCO 时，用从 examples 仓库
# 拉下来的 90 张校准图造一个 tiny 集 —— 这样不用等 13 GB 的 COCO 就能验证全链路。
CALIB="$DATA_DIR/examples/fast_neural_style/images/calib"
TINY_DIR="$DATA_DIR/tiny"
SUBSET_DIR="$DATA_DIR/coco${SUBSET_N}"
SMOKE_DATASET=""

if [[ "$DATASET_OK" == "1" ]]; then
    echo "  图片目录: $DS_IMG_SRC（$(count_imgs "$DS_IMG_SRC") 张）"
    echo "  训练集根: $DS_ROOT  ← run_batch.sh 的 --dataset 用这个（ImageFolder 语义）"
    SMOKE_DATASET="$DS_ROOT"
    if [[ "$SUBSET_N" != "0" ]]; then
        if [[ -d "$SUBSET_DIR/train2014" ]]; then
            echo "  子集已存在: $SUBSET_DIR（$(ls "$SUBSET_DIR/train2014" | wc -l) 张）"
        else
            python3 "$DEPLOY/cloud/make_subset.py" --src "$DS_IMG_SRC" \
                --dst "$SUBSET_DIR" --num "$SUBSET_N" --val-num 8 \
                || echo "  ⚠ 抽子集失败，不影响冒烟"
        fi
        echo "  → 之后跑网格用： --dataset $SUBSET_DIR"
    fi
elif [[ -n "$DATASET" ]]; then
    echo "  ⚠ --dataset 用不了：$DS_ERR"
    echo "    COCO 全量这样给（两种都行，会自动识别）："
    echo "      --dataset $DATA_DIR/coco            或  --dataset $DATA_DIR/coco/train2014"
elif [[ -d "$CALIB" ]]; then
    echo "  没给 --dataset（COCO 还没下），用校准图造一个冒烟用的小数据集"
    if [[ -d "$TINY_DIR/train2014" ]]; then
        echo "  已存在: $TINY_DIR（$(ls "$TINY_DIR/train2014" | wc -l) 张）"
    else
        python3 "$DEPLOY/cloud/make_subset.py" --src "$CALIB" \
            --dst "$TINY_DIR" --num 90 --val-num 4
    fi
    SMOKE_DATASET="$TINY_DIR"
    echo "  ⚠ 这个集只用于**验证链路**，不能用来训练出有意义的画质"
else
    echo "  ⚠ 既没有 --dataset，也找不到校准图 $CALIB"
    echo "    先确认 bootstrap 成功（它负责拉 examples 仓库）"
fi

hr "3/5 GPU 检查"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | sed 's/^/  /'
    python3 -c "import torch;print('  torch', torch.__version__, 'cuda=', torch.cuda.is_available())" 2>/dev/null \
        || echo "  ⚠ 读不到 torch"
    if ! python3 -c "import torch,sys;sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
        echo "  ⚠ CUDA 不可用 —— 如果这是「无卡模式开机」，先关机再正常开机"
    fi
else
    echo "  ⚠ 没有 nvidia-smi：当前应该是「无卡模式开机」"
    echo "    跑训练前记得关机 → 正常开机（带卡）"
fi

hr "4/5 冒烟（1 配置 / 1 epoch / 64x64）"
if [[ "$DO_SMOKE" == "0" ]]; then
    echo "  跳过（--no-smoke）"
else
    if [[ -z "$SMOKE_DATASET" ]]; then
        echo "  ⚠ 没有可用数据集，跳过冒烟。先下 COCO 或检查 bootstrap。"
    else
        echo "  用数据集: $SMOKE_DATASET"
        cd "$DATA_DIR" || exit 1
        # run_batch 会 source cloud/env.sh 里的 DATASET，这里显式覆盖
        "$DEPLOY/cloud/run_batch.sh" --smoke --dataset "$SMOKE_DATASET" \
            --out "$DATA_DIR/runs/smoke" || true
    fi
fi

hr "5/5 下一步"
cat <<EOF
  先下 COCO（13 GB，全量；下完再抽子集）：
    mkdir -p $DATA_DIR/coco && cd $DATA_DIR/coco
    wget -c http://images.cocodataset.org/zips/train2014.zip
    unzip -q train2014.zip && rm train2014.zip
  下完重跑一次本脚本，让它抽 1 万张子集并冒烟：
    bash $DEPLOY/cloud/web_quickstart.sh --dataset $DATA_DIR/coco

  跑小规模网格（摸 style_weight 方向）：
    cd $DATA_DIR
    ./Iris/deploy/cloud/run_batch.sh --dataset $SUBSET_DIR \\
        --out $DATA_DIR/runs/grid

  跑全量（注意 --dataset 是**根目录** $DATA_DIR/coco，不是 coco/train2014）：
    ./Iris/deploy/cloud/run_batch.sh --dataset $DATA_DIR/coco \\
        --out $DATA_DIR/runs/full --only c16b3

  结果：
    $DATA_DIR/runs/.../results.csv        ← 汇总表
    $DATA_DIR/runs/.../<name>_int8.tflite ← 交付物
    $DATA_DIR/runs/.../<name>_stylized.jpg ← 肉眼看效果

  详细说明： $DEPLOY/cloud/网页版运行手册.md
EOF
