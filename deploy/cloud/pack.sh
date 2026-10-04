#!/usr/bin/env bash
# 把 deploy/ 里**只需要上云的部分**打成一个很小的包（不含 .venv / .torch / out / calib）。
#
# 用法：deploy/cloud/pack.sh [输出路径]
#   -> 默认 deploy_code.tar.gz（几十 KB）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$(cd "$HERE/.." && pwd)"
OUT="${1:-$DEPLOY/cloud/deploy_code.tar.gz}"

cd "$DEPLOY"
# 排除上一次的产物：否则每次打包都会把上一个大包套进来，越滚越大
tar -czf "$OUT" \
    --exclude='__pycache__' \
    --exclude='deploy_code.tar.gz' \
    train quant verify env cloud

echo "已打包 -> $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "包含："
tar -tzf "$OUT" | sed 's/^/  /'
