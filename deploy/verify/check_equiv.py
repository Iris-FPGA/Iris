"""G4 门禁：INT8 量化精度对比（INT8 tflite vs FP32 参考）。

三种对比，含义不同
------------------
1. **float32 tflite  vs  int8 tflite** —— 纯量化损失。
   两者权重相同，只差量化，所以这个数字才真正反映"INT8 能不能用"。
2. **PyTorch FP32    vs  int8 tflite** —— 端到端误差（含 ONNX/TF 图转换 + 量化）。
3. **PyTorch FP32    vs  float32 tflite** —— 只验证图转换是否忠实（应当极高）。

用法
----
    python check_equiv.py --int8 ../out/flatfns_trained_int8.tflite \
        --float ../out/flatfns_trained_int8_float32.tflite \
        --content /path/to/a.jpg [--torch-model ../out/runs/smoke/xxx.model]
"""

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "train"))


def parse_args():
    p = argparse.ArgumentParser(description="INT8 vs FP32 精度对比（G4）")
    p.add_argument("--int8", required=True)
    p.add_argument("--float", default=None, help="同一模型的 float32 tflite（to_tflite.py --keep-float-tflite）")
    p.add_argument("--torch-model", default=None, help=".model 权重 + --channels/--blocks 可复现 PyTorch 参考")
    p.add_argument("--channels", type=int, default=16)
    p.add_argument("--blocks", type=int, default=3)
    p.add_argument("--content", required=True, help="内容图")
    p.add_argument("--json", default=None, help="把指标写成 JSON（供 run_batch.sh 汇总）")
    p.add_argument("--size", type=int, default=None, help="默认从 tflite 输入形状推断")
    return p.parse_args()


def run_tflite(path, img_f32):
    import tensorflow as tf
    it = tf.lite.Interpreter(path)
    it.allocate_tensors()
    d, o = it.get_input_details()[0], it.get_output_details()[0]
    x = img_f32
    if d["dtype"] == np.int8:
        scale, zp = d["quantization"]
        x = np.clip(np.round(img_f32 / scale) + zp, -128, 127).astype(np.int8)
    elif d["dtype"] == np.uint8:
        scale, zp = d["quantization"]
        x = np.clip(np.round(img_f32 / scale) + zp, 0, 255).astype(np.uint8)
    else:
        x = img_f32.astype(np.float32)
    it.set_tensor(d["index"], x)
    it.invoke()
    y = it.get_tensor(o["index"])
    if o["dtype"] in (np.int8, np.uint8):
        scale, zp = o["quantization"]
        y = (y.astype(np.float32) - zp) * scale
    return y.astype(np.float32)


def psnr(a, b, peak=255.0):
    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    return float("inf") if mse == 0 else 10 * np.log10(peak ** 2 / mse)


def ssim(a, b):
    try:
        from skimage.metrics import structural_similarity
        return float(structural_similarity(a, b, channel_axis=2, data_range=255))
    except Exception as e:
        return f"n/a ({type(e).__name__}: {e})"


def main():
    a = parse_args()
    from PIL import Image

    import tensorflow as tf
    it = tf.lite.Interpreter(a.int8)
    it.allocate_tensors()
    shape = it.get_input_details()[0]["shape"]
    h, w = int(shape[1]), int(shape[2])

    img = np.asarray(Image.open(a.content).convert("RGB").resize((w, h)), np.float32)
    img = (img * 255.0 if img.max() <= 1.0 else img)   # 模型输入域是 RGB 0~255
    img4 = img[None]

    ref_i8 = run_tflite(a.int8, img4)
    print(f"图像 {a.content} -> {w}x{h}   输入域 0~255")
    print(f"INT8 输出范围: [{ref_i8.min():.1f}, {ref_i8.max():.1f}]")

    rows = []

    if a.float:
        ref_f32 = run_tflite(a.float, img4)
        rows.append(("float32 tflite vs int8 tflite（纯量化损失）", psnr(ref_f32, ref_i8), ssim(ref_f32[0], ref_i8[0])))

    if a.torch_model:
        import torch
        from flatfns_model import FlatFNS
        net = FlatFNS(a.channels, a.blocks)
        net.load_state_dict(torch.load(a.torch_model, map_location="cpu"), strict=True)
        net.eval()
        with torch.no_grad():
            t = net(torch.from_numpy(img4.transpose(0, 3, 1, 2)))     # NCHW
        torch_nhwc = t.numpy().transpose(0, 2, 3, 1)
        rows.append(("PyTorch FP32 vs int8 tflite（端到端）", psnr(torch_nhwc, ref_i8), ssim(torch_nhwc[0], ref_i8[0])))
        if a.float:
            rows.append(("PyTorch FP32 vs float32 tflite（图转换忠实度）", psnr(torch_nhwc, ref_f32), ssim(torch_nhwc[0], ref_f32[0])))

    print(f"\n{'对比':<44}{'PSNR(dB)':>10}{'SSIM':>10}")
    print("-" * 64)
    for name, p, s in rows:
        ps = f"{p:.2f}" if isinstance(p, float) and np.isfinite(p) else str(p)
        ss = f"{s:.4f}" if isinstance(s, float) else str(s)
        print(f"{name:<44}{ps:>10}{ss:>10}")

    print("\n判据：风格迁移 PTQ 的常见接受区间是 PSNR ≥ 25~28 dB；")
    print("      '图转换忠实度' 一项应显著高于量化项（说明误差主要来自量化本身，而不是图转换）。")

    # 存一张对比图，便于肉眼看
    try:
        out = os.path.splitext(a.int8)[0] + "_compare.png"
        img8 = np.clip(ref_i8[0], 0, 255).astype(np.uint8)
        Image.fromarray(img8).save(out)
        print(f"\nINT8 输出图 -> {out}")
    except Exception as e:
        print(f"（存图失败：{e}）")

    # 机器可读输出，供 run_batch.sh 汇总
    if a.json:
        import json
        def num(x):
            return None if isinstance(x, str) else (
                float(x) if isinstance(x, (int, float)) and np.isfinite(x) else None)
        rec = {"model": os.path.abspath(a.int8), "content": os.path.abspath(a.content),
               "input_size": [h, w],
               "int8_output_range": [float(ref_i8.min()), float(ref_i8.max())],
               "metrics": {}}
        for name, p, s in rows:
            key = ("quant_only" if "纯量化损失" in name
                   else "end_to_end" if "端到端" in name
                   else "graph_fidelity")
            rec["metrics"][key] = {"psnr_db": num(p), "ssim": num(s)}
        with open(a.json, "w") as f:
            json.dump(rec, f, indent=2, ensure_ascii=False)
        print(f"JSON -> {a.json}")


if __name__ == "__main__":
    main()
