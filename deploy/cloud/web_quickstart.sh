#!/usr/bin/env bash
# 网页端一键：取到代码后，把「准备工作 + 冒烟」一次跑完。
#
# 专为在 JupyterLab / VSCode 网页终端里**粘贴一行**用，不需要 SSH。
#
# 用法（在网页终端里粘贴）：
#   bash /root/gpufree-data/Iris/deploy/cloud/web_quickstart.sh \
#        --dataset /root/gpufree-data/coco/train2014
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
[[ -n "$DATASET" ]] && ARGS+=(--dataset "$DATASET")
[[ "$MIRROR" == "0" ]] && ARGS+=(--no-mirror)
"$DEPLOY/cloud/bootstrap.sh" "${ARGS[@]}" || echo "  ⚠ bootstrap 有告警，继续"

hr "2/5 抽训练子集"
if [[ "$SUBSET_N" == "0" ]]; then
    echo "  跳过（--no-subset）"
elif [[ -n "$DATASET" && -d "$DATASET" ]]; then
    SUBSET_DIR="$DATA_DIR/coco${SUBSET_N}"
    if [[ -d "$SUBSET_DIR/train2014" ]]; then
        echo "  已存在，跳过: $SUBSET_DIR（$(ls "$SUBSET_DIR/train2014" | wc -l) 张）"
    else
        python3 "$DEPLOY/cloud/make_subset.py" --src "$DATASET" \
            --dst "$SUBSET_DIR" --num "$SUBSET_N" --val-num 8
    fi
    echo
    echo "  → 之后跑网格用： --dataset $SUBSET_DIR"
else
    echo "  跳过（没给 --dataset 或目录不存在）"
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
    if [[ -z "$DATASET" || ! -d "$DATASET" ]]; then
        echo "  ⚠ 没有可用数据集，冒烟会失败。先给 --dataset，或先下 COCO。"
    else
        cd "$DATA_DIR" || exit 1
        "$DEPLOY/cloud/run_batch.sh" --smoke --out "$DATA_DIR/runs/smoke" || true
    fi
fi

hr "5/5 下一步"
cat <<EOF
  跑小规模网格（摸 style_weight 方向）：
    cd $DATA_DIR
    ./Iris/deploy/cloud/run_batch.sh --dataset $DATA_DIR/coco${SUBSET_N} \\
        --out $DATA_DIR/runs/grid

  跑全量（改一下 env.sh 里的 DATASET，或直接给 --dataset）：
    ./Iris/deploy/cloud/run_batch.sh --dataset $DATA_DIR/coco/train2014 \\
        --out $DATA_DIR/runs/full --only c16b3

  结果：
    $DATA_DIR/runs/.../results.csv        ← 汇总表
    $DATA_DIR/runs/.../<name>_int8.tflite ← 交付物
    $DATA_DIR/runs/.../<name>_stylized.jpg ← 肉眼看效果

  详细说明： $DEPLOY/cloud/网页版运行手册.md
EOF
