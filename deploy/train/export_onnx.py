"""FlatFNS: PyTorch -> ONNX，并执行 G1 门禁（ONNX 图算子白名单）。

用法
----
    python export_onnx.py --out ../out/flatfns.onnx                     # 随机权重（只为验证转换链路）
    python export_onnx.py --weights runs/epoch_2_xxx.model --out ../out/flatfns.onnx

做四件事
--------
1. 建网（可加载训练好的 `.model`）
2. **折叠 BatchNorm 进卷积**，并校验折叠前后数值一致
3. 导出 ONNX
4. **G1 门禁**：列出 ONNX 算子，断言只含 `Conv/Add/Relu(/Clip)` ——
   这一步在出 `.tflite` 之前就把 `Pad`(MIRROR_PAD)、`Resize`(RESIZE_NEAREST)、
   `InstanceNormalization`(MEAN/SQRT 链) 这类不合格算子拦下来。
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
import torch  # noqa: E402

from flatfns_model import FlatFNS, fuse_bn  # noqa: E402

# ONNX 图里允许出现的算子（对应 TinyML 白名单）
#   Conv -> CONV_2D, Add -> ADD, Relu -> 融合进 CONV_2D
#   Clip 仅当 --final-clamp 打开时出现 -> RELU + MINIMUM（都在白名单）
G1_ALLOWED = {"Conv", "Add", "Relu", "Clip"}


def parse_args():
    p = argparse.ArgumentParser(description="FlatFNS -> ONNX (+G1 算子门禁)")
    p.add_argument("--weights", default=None, help="训练好的 .model / state_dict；留空则用随机权重")
    p.add_argument("--out", default="flatfns.onnx", help="输出 ONNX 路径")
    p.add_argument("--channels", type=int, default=16)
    p.add_argument("--blocks", type=int, default=3)
    p.add_argument("--kernel-size", type=int, default=3)
    p.add_argument("--final-clamp", action="store_true")
    p.add_argument("--size", default="128",
                   help="导出用的固定输入尺寸：方形写 128；非方形写 WxH，如 160x120"
                        "（=640x480 的 1/4，正好整数倍放大到显示分辨率）")
    p.add_argument("--opset", type=int, default=18)
    p.add_argument("--seed", type=int, default=0)
    return p.parse_args()


def parse_size(s):
    """'128' -> (H=128, W=128)；'160x120' -> (H=120, W=160)，按 WxH 书写。"""
    s = str(s).lower().replace("*", "x").replace("×", "x")
    if "x" in s:
        w, h = (int(v) for v in s.split("x"))
        return h, w
    n = int(s)
    return n, n


def main():
    a = parse_args()
    H, W = parse_size(a.size)

    # ---- 1. 建网 ----
    torch.manual_seed(a.seed)
    net = FlatFNS(a.channels, a.blocks, a.kernel_size, a.final_clamp)
    if a.weights:
        sd = torch.load(a.weights, map_location="cpu")
        if isinstance(sd, dict) and "state_dict" in sd:
            sd = sd["state_dict"]
        net.load_state_dict(sd, strict=True)
        print(f"[1/4] 已加载权重 {a.weights}")
    else:
        print("[1/4] 未给 --weights，使用随机权重（仅用于验证转换链路是否合规）")
    net.eval()

    # ---- 2. 折叠 BN ----
    fused = fuse_bn(net)
    n_bn_before = sum(1 for m in net.modules() if isinstance(m, torch.nn.BatchNorm2d))
    n_bn_after = sum(1 for m in fused.modules() if isinstance(m, torch.nn.BatchNorm2d))
    x = torch.rand(1, 3, H, W) * 255
    with torch.no_grad():
        d = float((net(x) - fused(x)).abs().max())
    print(f"[2/4] BN 折叠: BatchNorm2d {n_bn_before} -> {n_bn_after}, max|Δ| = {d:.3e}")
    assert n_bn_after == 0, "BN 未完全折叠，图里会留下 MEAN/SQRT 链"
    assert d < 1e-3, f"BN 折叠误差过大: {d}"
    fused.eval()

    # ---- 3. 导出 ONNX ----
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    torch.onnx.export(
        fused, x, a.out, opset_version=a.opset,
        input_names=["input"], output_names=["output"],
        dynamic_axes=None, do_constant_folding=True,
    )
    print(f"[3/4] ONNX -> {a.out}   输入 1x3x{H}x{W}")

    # 数值校验：PyTorch vs onnxruntime
    import onnxruntime as ort
    np_in = (torch.rand(1, 3, H, W) * 255).numpy()
    with torch.no_grad():
        ref = fused(torch.from_numpy(np_in)).numpy()
    got = ort.InferenceSession(a.out).run(None, {"input": np_in})[0]
    diff = float(np.abs(ref - got).max())
    print(f"      ONNX 校验: max abs diff = {diff:.3e}" + ("  (OK)" if diff < 1 else "  (偏大!)"))
    assert diff < 1e-2, f"ONNX 与 PyTorch 数值不一致: {diff}"

    # ---- 4. G1 门禁 ----
    import collections
    import onnx
    model = onnx.load(a.out)
    ops = collections.Counter(n.op_type for n in model.graph.node)
    bad = {k: v for k, v in ops.items() if k not in G1_ALLOWED}
    print(f"[4/4] G1 门禁  ONNX 算子: {dict(ops)}")
    if bad:
        print(f"      ❌ 不在允许集合 {sorted(G1_ALLOWED)} 内: {bad}")
        print("      提示：出现 Pad 说明用了反射填充；出现 InstanceNormalization 说明没换 BN；"
              "出现 Resize 说明图里还有上采样。")
        sys.exit(1)
    print(f"      ✅ 通过（允许集合 {sorted(G1_ALLOWED)}）")

    meta = {
        "arch": "FlatFNS", "channels": a.channels, "blocks": a.blocks,
        "kernel_size": a.kernel_size, "final_clamp": a.final_clamp,
        "input_size": [H, W], "opset": a.opset,
        "weights": os.path.abspath(a.weights) if a.weights else None,
        "onnx_ops": dict(ops),
        "num_weight_params": fused.num_weight_params(),
        "macs_per_pixel": fused.macs_per_pixel(),
        "bn_fold_max_diff": d,
        "onnx_vs_torch_max_diff": diff,
    }
    with open(os.path.splitext(a.out)[0] + ".meta.json", "w") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    print("      元数据 ->", os.path.splitext(a.out)[0] + ".meta.json")


if __name__ == "__main__":
    main()
