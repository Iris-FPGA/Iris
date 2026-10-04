#!/usr/bin/env bash
# Efinity Linux 安装脚本（解压式安装，无需 root）
#
# 用法：
#   deploy/scripts/install-efinity.sh <efinity-<version>.tar.bz2> [安装根目录]
# 例：
#   deploy/scripts/install-efinity.sh ~/下载/efinity-2026.1.132.4.5.tar.bz2 /mnt/mydata/efinity
#
# 说明：Efinity 的 Linux 版就是 tar.bz2，官方安装指南（UG-EFN-INSTALL v4.1）只要求
#       “解压到你的用户目录”，没有 root 安装步骤、没有 license 章节。
#       license 是单独在 Efinix Support Center 申请（免费，需账号，通常绑定 MAC）。
#
# 本脚本不做的事：不下载（下载需 Efinix 账号登录）、不申请 license。
set -euo pipefail

TARBALL="${1:-}"
ROOT_DIR="${2:-/mnt/mydata/efinity}"

die() { echo "错误：$*" >&2; exit 1; }

[[ -n "$TARBALL" ]] || die "用法：$0 <efinity-<version>.tar.bz2> [安装根目录]"
[[ -f "$TARBALL" ]] || die "找不到安装包：$TARBALL"

echo "==> 0. 检查安装包"
file "$TARBALL" | head -1
case "$TARBALL" in
    *.tar.bz2|*.tbz2) : ;;
    *.tar.gz|*.tgz)   die "这是 gz 包，Linux 版应当是 .tar.bz2；请确认下的是 Linux 版而不是 Windows .msi" ;;
    *.msi)            die "这是 Windows 的 .msi，请到 Support Center 下 Linux 版 .tar.bz2" ;;
esac
ls -lh "$TARBALL"

echo "==> 1. 检查系统依赖（Ubuntu 20.04+ / JDK8+ / libxcb-cursor0）"
if command -v java >/dev/null 2>&1; then
    java -version 2>&1 | head -1
    # 官方已知问题：OpenJDK v24 及以上有兼容问题
    if java -version 2>&1 | grep -qE '"(2[4-9]|[3-9][0-9])'; then
        echo "  ⚠ 警告：检测到 JDK 24+，Efinix 文档记录其存在已知问题，建议降到 JDK 8/11/17"
    fi
else
    echo "  ⚠ 未找到 java；配置 Sapphire SoC 等 IP 时需要它（apt install openjdk-17-jre）"
fi
ldconfig -p 2>/dev/null | grep -q libxcb-cursor && echo "  libxcb-cursor0: OK" \
    || echo "  ⚠ 缺少 libxcb-cursor0：sudo apt install libxcb-cursor0"

echo "==> 2. 解压到 $ROOT_DIR"
mkdir -p "$ROOT_DIR"
# 记录解压前后，便于定位 setup.sh
tar -xjvf "$TARBALL" -C "$ROOT_DIR"

echo "==> 3. 定位 EFINITY_HOME（含 bin/setup.sh 的目录）"
EFINITY_HOME="$(find "$ROOT_DIR" -maxdepth 4 -type f -name setup.sh -path '*/bin/*' \
                -printf '%h\n' 2>/dev/null | sed 's|/bin$||' | sort -V | tail -1)"
[[ -n "$EFINITY_HOME" ]] || die "解压后没找到 bin/setup.sh，请人工检查 $ROOT_DIR"
echo "  EFINITY_HOME=$EFINITY_HOME"

echo "==> 4. 验证工具链"
# 官方 setup.sh 未按 strict-mode 编写，临时关掉 errexit 再 source
set +e +u; set +o pipefail
# shellcheck disable=SC1091
source "$EFINITY_HOME/bin/setup.sh" >/dev/null 2>&1
set -e -u; set -o pipefail
if command -v efx_run >/dev/null 2>&1; then
    echo "  efx_run: $(command -v efx_run)"
    efx_run --version 2>&1 | head -3 || true
else
    echo "  ⚠ source setup.sh 后仍找不到 efx_run，请人工检查"
fi

echo "==> 5. 写入 Iris 工程配置（供 .script/build-iris 使用）"
IRIS_WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF_DIR="$IRIS_WS/Iris/path"
if [[ -d "$IRIS_WS/Iris" ]]; then
    mkdir -p "$CONF_DIR"
    printf '%s\n' "$EFINITY_HOME" > "$CONF_DIR/efinity_home"
    echo "  已写入 $CONF_DIR/efinity_home"
else
    echo "  跳过（未找到 Iris 仓库）"
fi

echo
echo "==> 完成。下一步："
echo "    1) source $EFINITY_HOME/bin/setup.sh"
echo "    2) 启动 GUI: python3 $IRIS_WS/tinyml/tools/tinyml_generator/tinyml_generator.py"
echo "    3) 若 GUI 提示 license：在 Efinix Support Center 用账号申请（免费，绑定 MAC）"
echo
echo "  本机 MAC（申请 license 用）："
for i in /sys/class/net/*/address; do
    n=$(basename "$(dirname "$i")"); a=$(cat "$i")
    [[ "$a" == "00:00:00:00:00:00" ]] && continue
    echo "    $n  $a"
done
