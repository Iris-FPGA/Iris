"""FlatFNS: ONNX -> TF SavedModel -> **全整数 INT8** .tflite。

为什么不用队友的 `model2tf_lite.py`
----------------------------------
它第 93 行调 `tf.lite.TFLiteConverter.from_saved_model(a.saved_model)`，
但当前 onnx2tf（2.6.9）默认的 `flatbuffer_direct` 后端**只输出 .tflite，不生成
saved_model.pb**，于是必然报：

    OSError: SavedModel file does not exist at: saved_model/{saved_model.pbtxt|saved_model.pb}

本脚本的修法：**显式让 onnx2tf 产出 SavedModel**（`-fdosm`，需要 `tf_keras`），
再用标准的 `TFLiteConverter.from_saved_model(...)` 自己做全整数量化。
这样量化参数（int8 进 / int8 出、per-channel 权重、校准集）全都由我们控制。

量化规格（对应《TinyML模型训练量化与Ti60F225部署计划.md》§7.3/§7.4）
---------------------------------------------------------------
    optimizations        = [DEFAULT]
    representative_dataset = 真实校准图（RGB 0~255，NHWC）
    supported_ops        = [TFLITE_BUILTINS_INT8]
    inference_input_type = int8
    inference_output_type= int8

用法
----
    python to_tflite.py --onnx ../out/flatfns.onnx \
        --calib /mnt/mydata/Iris/examples/fast_neural_style/images/calib \
        --out ../out/flatfns_int8.tflite
"""

import argparse
import glob
import os
import subprocess
import sys


def parse_args():
    p = argparse.ArgumentParser(description="ONNX -> SavedModel -> INT8 tflite（全整数）")
    p.add_argument("--onnx", required=True)
    p.add_argument("--out", required=True, help="输出 int8 .tflite 路径")
    p.add_argument("--calib", required=True, help="校准图目录（递归找 jpg/png）")
    p.add_argument("--saved-model", default=None, help="SavedModel 输出目录（默认 <out>_saved_model）")
    p.add_argument("--size", type=int, default=None,
                   help="校准图 resize 到该方形尺寸；默认从 SavedModel 签名自动推断")
    p.add_argument("--num-calib", type=int, default=0, help="最多用多少张校准图（0=全部）")
    p.add_argument("--skip-onnx2tf", action="store_true", help="复用已有 SavedModel")
    p.add_argument("--keep-float-tflite", action="store_true",
                   help="同时保留 float32 tflite，用于对比画质")
    return p.parse_args()


def step1_saved_model(args) -> str:
    """onnx2tf 产出 SavedModel（这是队友脚本缺的那一步）。"""
    sm = args.saved_model or (os.path.splitext(args.out)[0] + "_saved_model")
    if args.skip_onnx2tf and os.path.exists(os.path.join(sm, "saved_model.pb")):
        print(f"[1/4] 复用已存在的 SavedModel: {sm}")
        return sm

    cmd = ["onnx2tf", "-i", args.onnx, "-o", sm, "-fdosm", "-b", "1"]
    print("[1/4] " + " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(os.path.join(sm, "saved_model.pb")):
        print(r.stdout[-3000:])
        print(r.stderr[-3000:], file=sys.stderr)
        sys.exit(
            "[1/4] onnx2tf 未生成 SavedModel。\n"
            "      需要可选依赖：pip install tf_keras\n"
            "      （缺少时 onnx2tf 会报 'requires optional dependencies: tensorflow, tf_keras'）"
        )
    print(f"      SavedModel -> {sm}")
    return sm


def _input_hwc(saved_model: str):
    """从 SavedModel 签名取输入形状（NHWC），用于确定校准图 resize 尺寸。"""
    import tensorflow as tf
    fn = tf.saved_model.load(saved_model).signatures["serving_default"]
    spec = list(fn.structured_input_signature[1].values())[0]
    shape = spec.shape.as_list()
    return shape


def step2_int8(args, saved_model: str) -> None:
    import numpy as np
    import tensorflow as tf
    from PIL import Image

    files = sorted(glob.glob(os.path.join(args.calib, "**", "*.jpg"), recursive=True) +
                   glob.glob(os.path.join(args.calib, "**", "*.png"), recursive=True))
    if not files:
        sys.exit(f"[2/4] 校准集为空: {args.calib}/**/*.jpg|png")
    if args.num_calib:
        files = files[:args.num_calib]

    shape = _input_hwc(saved_model)
    size = args.size or (shape[1] if len(shape) == 4 and isinstance(shape[1], int) else 256)
    print(f"[2/4] 校准集 {len(files)} 张，SavedModel 输入 {shape}，resize 到 {size}x{size}")
    print(f"      输入域 RGB 0~255（与训练一致，不做 ImageNet 归一化）")

    def rep():
        for f in files:
            arr = np.asarray(Image.open(f).convert("RGB").resize((size, size)), np.float32)
            yield [arr[None]]          # NHWC, float32, 0~255

    c = tf.lite.TFLiteConverter.from_saved_model(saved_model)
    c.optimizations = [tf.lite.Optimize.DEFAULT]
    c.representative_dataset = rep
    c.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    c.inference_input_type = tf.int8
    c.inference_output_type = tf.int8

    data = c.convert()
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"[2/4] INT8 TFLite -> {args.out}  ({len(data)/1024:.1f} KB)")

    if args.keep_float_tflite:
        c2 = tf.lite.TFLiteConverter.from_saved_model(saved_model)
        p = os.path.splitext(args.out)[0] + "_float32.tflite"
        with open(p, "wb") as f:
            f.write(c2.convert())
        print(f"      float32 参考 -> {p}")


def step3_report(args) -> None:
    import numpy as np
    import tensorflow as tf
    it = tf.lite.Interpreter(args.out)
    it.allocate_tensors()
    d, o = it.get_input_details()[0], it.get_output_details()[0]
    print("[3/4] 输入/输出张量：")
    print(f"      input  {d['name']}  dtype={np.dtype(d['dtype']).name} shape={tuple(d['shape'])}")
    print(f"             scale={d['quantization'][0]:.8g} zero_point={d['quantization'][1]}")
    print(f"      output {o['name']}  dtype={np.dtype(o['dtype']).name} shape={tuple(o['shape'])}")
    print(f"             scale={o['quantization'][0]:.8g} zero_point={o['quantization'][1]}")


if __name__ == "__main__":
    # 让 `onnx2tf` 可执行文件可被 subprocess 找到
    os.environ["PATH"] = os.path.dirname(sys.executable) + os.pathsep + os.environ.get("PATH", "")
    a = parse_args()
    sm = step1_saved_model(a)
    step2_int8(a, sm)
    step3_report(a)
    print("[4/4] 下一步： python ops_inventory.py --model " + a.out)
