#!/usr/bin/env bash
# 一条命令把代码送上云并初始化（算力自由 / gpufree.cn）。
#
# 前置（只需做一次，且必须你本人做）：
#   1. 在 gpufree.cn 控制台租一个实例（要你的账号 / 实名认证 / 支付）
#   2. 控制台 → 个人中心 → 密钥管理 → 新建密钥，粘贴本机公钥：
#        cat ~/.ssh/id_ed25519.pub
#      （本机已有：ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHdDcJEoK9smlHOGEiSh3SZODacSYlXmtgztuuNy2u4E 13869662005@163.com）
#      —— 走公钥是因为本机没装 sshpass 且 sudo 需密码，密码登录无法自动化
#
# 用法：
#   deploy/scripts/cloud-up.sh --host 183.147.142.40 --port 7777 \
#       --dataset /root/gpufree-data/coco [--smoke]
#
#   ⚠ --dataset 传 **ImageFolder 根目录**（.../coco，图片在它的 train2014/ 里），
#     不是 .../coco/train2014 —— run_batch.sh 会用 ImageFolder 去读它。
#
# 之后（云上训练）：
#   ssh root@<host> -p <port> 'cd /root/gpufree-data && ./deploy/cloud/run_batch.sh'
set -euo pipefail

HOST=""; PORT=""; USER="root"; KEY="$HOME/.ssh/id_ed25519"
REMOTE_BASE="/root/gpufree-data"; DATASET=""; SMOKE=0; MIRROR=1; SKIP_BOOTSTRAP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --key)  KEY="$2";  shift 2 ;;
        --remote-base) REMOTE_BASE="$2"; shift 2 ;;
        --dataset) DATASET="$2"; shift 2 ;;
        --smoke) SMOKE=1; shift ;;
        --no-mirror) MIRROR=0; shift ;;
        --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$HOST" && -n "$PORT" ]] || { echo "必须给 --host 和 --port" >&2; exit 1; }
[[ -f "$KEY" ]] || { echo "找不到私钥 $KEY" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$(cd "$HERE/.." && pwd)"
SSH_OPTS=(-i "$KEY" -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=15 -o ServerAliveInterval=30)
TARGET="$USER@$HOST"

echo "==> 1/5 测试 SSH 连通性（公钥免密）"
if ! ssh "${SSH_OPTS[@]}" "$TARGET" 'echo ok' >/dev/null 2>&1; then
    cat >&2 <<EOF
❌ 连不上或公钥没生效：$TARGET -p $PORT

逐项排查：
  1. 实例是否处于「运行中」（关了机连不上）
  2. 公钥是否已加到 gpufree 控制台 → 个人中心 → 密钥管理，
     并且内容是这一整行（含结尾的邮箱注释）：
         $(cat "$KEY.pub" 2>/dev/null || echo '（读不到公钥）')
  3. 公钥可能需要重启实例才生效 —— 关机再开一次试试
  4. host/port 抄错没有？平台给的是 ssh root@IP -p 端口，端口不是 22
  5. 手动试一次：ssh $TARGET -p $PORT
EOF
    exit 1
fi
echo "    ✅ 已连上 $TARGET:$PORT（$(ssh "${SSH_OPTS[@]}" "$TARGET" 'hostname; nproc; free -g | awk "/Mem:/{print \$2\" GB RAM\"}"' 2>/dev/null | tr '\n' ' '))"

echo "==> 2/5 看看云上的卡和盘"
ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s' <<'EOF' || true
echo -n "  GPU: "; command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | paste -sd' | ' || echo "(没有 nvidia-smi —— 可能当前是无卡模式)"
echo -n "  torch: "; python3 -c "import torch;print(torch.__version__, 'cuda=', torch.cuda.is_available())" 2>/dev/null || echo "(未安装)"
echo -n "  磁盘: "; df -h /root/gpufree-data 2>/dev/null | tail -1 || echo "(/root/gpufree-data 不存在)"
echo -n "  python: "; python3 -V 2>&1
EOF

echo "==> 3/5 本机打包 + 上传"
"$DEPLOY/cloud/pack.sh" >/dev/null
TAR="$DEPLOY/cloud/deploy_code.tar.gz"
echo "    $(du -h "$TAR" | cut -f1) -> $TARGET:/root/"
scp -i "$KEY" -P "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -q \
    "$TAR" "$TARGET:/root/deploy_code.tar.gz"

echo "==> 4/5 云上解开到 $REMOTE_BASE/deploy"
ssh "${SSH_OPTS[@]}" "$TARGET" REMOTE_BASE="$REMOTE_BASE" 'bash -s' <<'EOF'
set -e
mkdir -p "$REMOTE_BASE"
cd "$REMOTE_BASE"
rm -rf .deploy_unpack deploy_new
mkdir -p .deploy_unpack
tar -xzf /root/deploy_code.tar.gz -C .deploy_unpack
mkdir -p deploy_new
mv .deploy_unpack/* deploy_new/
rm -rf .deploy_unpack
if [[ -d deploy ]]; then
    echo "    已存在 deploy/，备份为 deploy.bak.$(date +%s)"
    mv deploy "deploy.bak.$(date +%s)"
fi
mv deploy_new deploy
rm -f /root/deploy_code.tar.gz
echo "    文件数: $(find deploy -type f | wc -l)"
EOF

if [[ "$SKIP_BOOTSTRAP" == "0" ]]; then
    echo "==> 5/5 云上 bootstrap（自检 + 拉素材 + 生成 env.sh）"
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "REMOTE_BASE='$REMOTE_BASE' DATASET='$DATASET' MIRROR='$MIRROR' bash -s" <<'EOF'
set -e
cd "$REMOTE_BASE"
ARGS=(--data-dir "$REMOTE_BASE")
[[ -n "$DATASET" ]] && ARGS+=(--dataset "$DATASET")
[[ "$MIRROR" == "0" ]] && ARGS+=(--no-mirror)
./deploy/cloud/bootstrap.sh "${ARGS[@]}" || {
    echo "⚠ bootstrap 有告警，但不致命，继续"; }
EOF
else
    echo "==> 5/5 跳过 bootstrap"
fi

if [[ "$SMOKE" == "1" ]]; then
    echo "==> 额外：跑冒烟（1 配置 / 1 epoch / 64x64）"
    ssh "${SSH_OPTS[@]}" "$TARGET" "cd $REMOTE_BASE && ./deploy/cloud/run_batch.sh --smoke" || true
fi

cat <<EOF

✅ 上云完成
   代码位置 : $REMOTE_BASE/deploy
   登录方式 : ssh $TARGET -p $PORT

下一步（在云上）：
   cd $REMOTE_BASE
   ./deploy/cloud/run_batch.sh --smoke                    # 先验链路
   ./deploy/cloud/make_subset.py --src <COCO>/train2014 \\
        --dst $REMOTE_BASE/coco10k --num 10000             # 抽子集
   ./deploy/cloud/run_batch.sh --dataset $REMOTE_BASE/coco10k \\
        --out $REMOTE_BASE/runs/grid10k                    # 跑网格

详细清单见 $REMOTE_BASE/deploy/cloud/运行手册.md
EOF
