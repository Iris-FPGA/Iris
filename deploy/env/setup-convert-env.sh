#!/usr/bin/env bash
# 在本机建立「转换/量化」环境（.model -> ONNX -> INT8 .tflite -> 算子合规校验）
#
# 用法：deploy/env/setup-convert-env.sh
#
# 为什么单独搞一套：队友的 conda env `yolo` 是 PyTorch-only，
# 是他「放弃 TFLite 路线」后配的环境，里面**没有 TensorFlow**。
# 全整数量化 + TFLiteConverter + onnx2tf 必须另配。
#
# 本脚本用 CPU 版即可：量化、算子清单、PSNR/SSIM 校验都不需要 GPU。
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.venv"
REQ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/requirements-convert.txt"

# 国内镜像（清华）
PIP_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"

# pip 缓存放到工作区内，避免写 ~/.cache 被沙箱拦下
export PIP_CACHE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.pip-cache"

echo "==> 1/5 创建 venv: $ENV_DIR"
if [[ ! -x "$ENV_DIR/bin/python" ]]; then
    python3 -m venv "$ENV_DIR"
fi
PY="$ENV_DIR/bin/python"
"$PY" -V

echo "==> 2/5 升级 pip"
"$PY" -m pip install -q --upgrade pip -i "$PIP_INDEX"

echo "==> 3/5 安装 TensorFlow / onnx / onnxruntime / onnx2tf / 图像与指标库"
echo "    源: $PIP_INDEX"
"$PY" -m pip install -i "$PIP_INDEX" -r "$REQ"

echo "==> 4/5 安装 PyTorch（CPU 版）"
# 为什么不用 pytorch.org：国内实测 ~50 KB/s，196 MB 的 wheel 要下 1 小时。
# 阿里云 pytorch-wheels 镜像实测 ~9.4 MB/s。这里直接下 wheel 再本地安装，
# 同时也避免 pip 从 PyPI 解析到 3 GB 的 CUDA 版（torch 2.14.1 + 一堆 nvidia-* 依赖）。
TORCH_VER="2.14.0"
TV_VER="0.29.0"
TAG="cp$("$PY" -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")')"
PLAT="manylinux_2_28_x86_64"
WHL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.wheels"
ALI="https://mirrors.aliyun.com/pytorch-wheels/cpu"

mkdir -p "$WHL_DIR"
for name in "torch-${TORCH_VER}" "torchvision-${TV_VER}"; do
    wheel="${name}+cpu-${TAG}-${TAG}-${PLAT}.whl"
    dest="$WHL_DIR/$wheel"
    if [[ ! -f "$dest" ]]; then
        echo "    下载 $wheel"
        curl -fL --retry 3 --connect-timeout 15 -o "$dest" \
             "$ALI/$(printf '%s' "$wheel" | sed 's/+/%2B/')" \
            || { echo "    镜像缺该文件，回退 pytorch.org（可能很慢）"; \
                 curl -fL --retry 3 -o "$dest" "https://download.pytorch.org/whl/cpu/$wheel"; }
    fi
    ls -lh "$dest" | awk '{printf "    %s  %s\n", $9, $5}'
done

"$PY" -m pip install -i "$PIP_INDEX" \
    "$WHL_DIR/torch-${TORCH_VER}+cpu-${TAG}-${TAG}-${PLAT}.whl" \
    "$WHL_DIR/torchvision-${TV_VER}+cpu-${TAG}-${TAG}-${PLAT}.whl"

echo "==> 5/5 验证"
"$PY" - <<'PYCODE'
import importlib, sys
print(f"python       {sys.version.split()[0]}")
mods = ["numpy", "PIL", "cv2", "skimage", "onnx", "onnxruntime",
        "tensorflow", "torch", "torchvision"]
ok = True
for m in mods:
    try:
        mod = importlib.import_module(m)
        print(f"{m:<13}{getattr(mod, '__version__', 'n/a')}")
    except Exception as e:
        ok = False
        print(f"{m:<13}!! 导入失败: {type(e).__name__}: {e}")

# TFLiteConverter 是这条链路的核心，单独验一下
try:
    import tensorflow as tf
    assert hasattr(tf.lite, "TFLiteConverter"), "缺少 tf.lite.TFLiteConverter"
    print("TFLiteConverter  OK")
except Exception as e:
    ok = False
    print(f"TFLiteConverter  !! {e}")

print("\n结果:", "全部就绪" if ok else "有缺失，见上面 !! 行")
sys.exit(0 if ok else 1)
PYCODE

echo
echo "==> 完成。激活方式： source $ENV_DIR/bin/activate"
