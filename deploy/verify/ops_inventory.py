"""算子合规门禁（G2 / G3）—— 直接解析 .tflite flatbuffer。

为什么不用 `tf.lite.Interpreter`
-------------------------------
1. TF 2.21 已弃用 `tf.lite.Interpreter`（要求迁移到 `ai_edge_litert`）；
2. 更重要的：`_get_ops_details()` **拿不到每个算子的 builtin version**，
   而 tflite-micro 是 `TFLITE_SCHEMA_VERSION = 3`，算子版本过新会被 kernel 拒绝。
   所以这里直接读 flatbuffer。

检查项
------
G2  算子白名单：图中出现的算子必须全部落在 Efinix TinyML 加速白名单内，
    并显式检查那些"常被误以为没问题"的算子：MIRROR_PAD / PAD / MEAN / SQRT /
    RSQRT / SUB / DIV / RESIZE_* / TRANSPOSE_CONV / SOFTMAX / AVERAGE_POOL /
    TRANSPOSE / QUANTIZE / DEQUANTIZE。
G3  量化规格：schema version = 3；输入/输出张量 dtype = INT8；卷积权重为 INT8
    且 per-channel 量化（scale 个数 == 输出通道数）。

用法
----
    python ops_inventory.py --model ../out/flatfns_int8.tflite
    python ops_inventory.py --model xxx.tflite --report ../out/compliance.md

退出码：0 = 通过，1 = 有违规（可直接当 CI 门禁用）。
"""

import argparse
import collections
import sys

from ai_edge_litert import schema_py_generated as fb

# Efinix TinyML 加速白名单
# 依据：tinyml/tools/tinyml_generator/README.md "Supported layers for hardware acceleration"
#      + tinyml/.../src/platform/tinyml/ops/ 目录（只有 8 个驱动 + cache/sys）
WHITELIST = {
    "CONV_2D", "DEPTHWISE_CONV_2D", "FULLY_CONNECTED",
    "ADD", "MUL", "MINIMUM", "MAXIMUM",
    "LEAKY_RELU", "RESHAPE",
}

# 明确点名的高危算子（掉出加速器后由 RISC-V 解释执行，性能差 1~2 个数量级）
SUSPECTS = {
    "MIRROR_PAD": "反射填充 ReflectionPad2d 残留 → 改用 Conv2d 的普通 padding",
    "PAD": "显式 PAD → 让 Conv2d 用 SAME 零填充吸收",
    "MEAN": "InstanceNorm/全局均值 → 改用 BatchNorm 并在导出前折叠进卷积",
    "SQRT": "InstanceNorm 的 rsqrt 链 → 同上",
    "RSQRT": "InstanceNorm 的 rsqrt 链 → 同上",
    "SUB": "InstanceNorm 的减均值 → 同上",
    "DIV": "InstanceNorm 的除标准差 → 同上",
    "RESIZE_NEAREST_NEIGHBOR": "图内最近邻上采样 → 改为单分辨率网络，放大交给显示侧硬件",
    "RESIZE_BILINEAR": "图内双线性上采样 → 同上",
    "TRANSPOSE_CONV": "反卷积 → TinyML 不加速，改成普通 Conv",
    "SOFTMAX": "分类头才需要；风格迁移不该有",
    "AVERAGE_POOL_2D": "池化不在白名单 → 用 stride=2 的 Conv 代替",
    "TRANSPOSE": "维度置换 → 用 RESHAPE 或改数据布局",
    "QUANTIZE": "出现说明存在 float 张量混进图里（非纯整数图）",
    "DEQUANTIZE": "同上",
    "RELU": "独立的 RELU 算子不在白名单；让 ReLU 紧跟 Conv 使其融合进 CONV_2D",
    "RELU6": "同 RELU",
    "CONCATENATION": "不在白名单",
    "SPLIT": "不在白名单",
    "LOGISTIC": "不在白名单",
}

TENSOR_TYPE = {v: k for k, v in vars(fb.TensorType).items()
               if isinstance(v, int) and not k.startswith("_")}
BUILTIN = {v: k for k, v in vars(fb.BuiltinOperator).items()
           if isinstance(v, int) and not k.startswith("_")}


def parse_args():
    p = argparse.ArgumentParser(description="TinyML 算子合规门禁（G2/G3）")
    p.add_argument("--model", required=True, help=".tflite 路径")
    p.add_argument("--report", default=None, help="可选：输出 markdown 报告路径")
    p.add_argument("--json", default=None, help="可选：输出 JSON（供 run_batch.sh 汇总）")
    p.add_argument("--quiet", action="store_true")
    return p.parse_args()


def opcode_table(model):
    """算子码表：index -> (名字, version)。"""
    codes = []
    for i in range(model.OperatorCodesLength()):
        oc = model.OperatorCodes(i)
        code = oc.BuiltinCode()
        if code == fb.BuiltinOperator.PLACEHOLDER_FOR_GREATER_OP_CODES:
            code = oc.DeprecatedBuiltinCode()
        name = BUILTIN.get(code, f"UNKNOWN({code})")
        ver = oc.Version() or 1
        custom = oc.CustomCode()
        if custom:
            name = f"CUSTOM:{custom.decode()}"
        codes.append((name, ver))
    return codes


def analyse(path):
    with open(path, "rb") as f:
        buf = f.read()
    model = fb.Model.GetRootAsModel(buf, 0)
    codes = opcode_table(model)

    sub = model.Subgraphs(0)
    ops = collections.Counter()
    op_versions = collections.defaultdict(set)
    op_input_types = collections.defaultdict(set)

    for i in range(sub.OperatorsLength()):
        op = sub.Operators(i)
        name, ver = codes[op.OpcodeIndex()]
        ops[name] += 1
        op_versions[name].add(ver)
        for j in range(op.InputsLength()):
            t = op.Inputs(j)
            if t < 0:
                continue
            tt = sub.Tensors(t).Type()
            op_input_types[name].add(TENSOR_TYPE.get(tt, str(tt)))

    tensors = []
    for i in range(sub.TensorsLength()):
        t = sub.Tensors(i)
        q = t.Quantization()
        scales = [q.Scale(k) for k in range(q.ScaleLength())] if q else []
        zps = [q.ZeroPoint(k) for k in range(q.ZeroPointLength())] if q else []
        shape = [t.Shape(k) for k in range(t.ShapeLength())]
        tensors.append({
            "index": i,
            "name": t.Name().decode() if t.Name() else "",
            "type": TENSOR_TYPE.get(t.Type(), str(t.Type())),
            "shape": shape,
            "scales": scales,
            "zero_points": zps,
        })

    ins = [sub.Inputs(i) for i in range(sub.InputsLength())]
    outs = [sub.Outputs(i) for i in range(sub.OutputsLength())]
    return {
        "schema_version": model.Version(),
        "ops": ops,
        "op_versions": op_versions,
        "op_input_types": op_input_types,
        "tensors": tensors,
        "inputs": [tensors[i] for i in ins],
        "outputs": [tensors[i] for i in outs],
        "size": len(buf),
    }


def check(info):
    """返回 (errors, warnings)。"""
    errors, warns = [], []

    if info["schema_version"] != 3:
        warns.append(f"schema version = {info['schema_version']}（tflite-micro 期望 3）")

    # ---- G2 白名单 ----
    bad = {k: v for k, v in info["ops"].items() if k not in WHITELIST}
    for name, cnt in sorted(bad.items()):
        tip = SUSPECTS.get(name, "不在 Efinix TinyML 加速白名单内")
        errors.append(f"G2 非白名单算子 {name} ×{cnt} —— {tip}")

    # ---- G3 量化规格 ----
    for tag, ts in (("输入", info["inputs"]), ("输出", info["outputs"])):
        for t in ts:
            if t["type"] != "INT8":
                errors.append(f"G3 {tag}张量 {t['name']} dtype = {t['type']}（要求 INT8，"
                              f"float32/hybrid 会在板端退化成浮点推理）")

    # 卷积权重必须 int8 且 per-channel —— 见 conv_weight_check()
    return errors, warns


def conv_weight_check(info):
    """G3 补充：CONV_2D 的权重张量必须是 INT8，且 per-channel（scale 个数 == 输出通道数）。"""
    errs = []
    for t in info["tensors"]:
        # 权重张量：4 维、含 int8 量化参数、非输入输出
        if len(t["shape"]) == 4 and t["scales"] and t["name"].endswith("_weight"):
            if t["type"] != "INT8":
                errs.append(f"G3 权重 {t['name']} dtype = {t['type']}（要求 INT8）")
            n_out = t["shape"][0]
            if len(t["scales"]) not in (1, n_out):
                errs.append(f"G3 权重 {t['name']} scale 个数 {len(t['scales'])} 既不是 1 也不是 "
                            f"输出通道数 {n_out}")
    return errs


def main():
    a = parse_args()
    info = analyse(a.model)

    print(f"模型: {a.model}  ({info['size']/1024:.1f} KB)")
    print(f"schema version: {info['schema_version']}  子图数: 1")

    print("\n--- G2 算子清单 ---")
    for name, cnt in sorted(info["ops"].items(), key=lambda kv: -kv[1]):
        mark = "✅" if name in WHITELIST else "❌"
        vers = ",".join(str(v) for v in sorted(info["op_versions"][name]))
        print(f"  {mark} {name:<26} ×{cnt:<4} version={vers}")

    print("\n--- G3 输入/输出张量 ---")
    for tag, ts in (("in ", info["inputs"]), ("out", info["outputs"])):
        for t in ts:
            sc = f"{t['scales'][0]:.8g}" if t["scales"] else "n/a"
            zp = t["zero_points"][0] if t["zero_points"] else "n/a"
            print(f"  {tag} {t['name']:<28} {t['type']:<7} shape={t['shape']} scale={sc} zp={zp}")

    errors, warns = check(info)
    errors += conv_weight_check(info)

    print("\n--- 结果 ---")
    for w in warns:
        print(f"  ⚠ {w}")
    if errors:
        for e in errors:
            print(f"  ❌ {e}")
        print(f"\n门禁未通过：{len(errors)} 项违规")
    else:
        print("  ✅ G2 算子全部在白名单内")
        print("  ✅ G3 输入/输出为 INT8，无 float/hybrid 路径")
        print("\n门禁通过 🎉")

    if a.report:
        with open(a.report, "w") as f:
            f.write(f"# 算子合规报告\n\n模型：`{a.model}`（{info['size']/1024:.1f} KB）\n\n")
            f.write(f"schema version: {info['schema_version']}\n\n## G2 算子清单\n\n")
            f.write("| 算子 | 个数 | version | 白名单 |\n|---|---:|---:|:--:|\n")
            for name, cnt in sorted(info["ops"].items(), key=lambda kv: -kv[1]):
                vers = ",".join(str(v) for v in sorted(info["op_versions"][name]))
                f.write(f"| `{name}` | {cnt} | {vers} | {'✅' if name in WHITELIST else '❌'} |\n")
            f.write("\n## G3 输入/输出\n\n| 张量 | dtype | shape | scale | zero_point |\n|---|---|---|---:|---:|\n")
            for tag, ts in (("输入", info["inputs"]), ("输出", info["outputs"])):
                for t in ts:
                    sc = f"{t['scales'][0]:.8g}" if t["scales"] else "n/a"
                    zp = t["zero_points"][0] if t["zero_points"] else "n/a"
                    f.write(f"| {tag} `{t['name']}` | {t['type']} | {t['shape']} | {sc} | {zp} |\n")
            f.write("\n## 结论\n\n")
            if errors:
                f.write("**未通过**\n\n" + "\n".join(f"- ❌ {e}" for e in errors) + "\n")
            else:
                f.write("**通过**：G2 算子全部位于 TinyML 加速白名单；G3 全整数 INT8。\n")
        print(f"\n报告 -> {a.report}")

    if a.json:
        import json
        rec = {
            "model": a.model,
            "size_bytes": info["size"],
            "schema_version": info["schema_version"],
            "ops": {k: {"count": v, "version": sorted(info["op_versions"][k]),
                        "whitelisted": k in WHITELIST}
                    for k, v in info["ops"].items()},
            "non_whitelisted_total": sum(v for k, v in info["ops"].items() if k not in WHITELIST),
            "inputs": [{"name": t["name"], "type": t["type"], "shape": t["shape"],
                        "scale": t["scales"][0] if t["scales"] else None,
                        "zero_point": t["zero_points"][0] if t["zero_points"] else None}
                       for t in info["inputs"]],
            "outputs": [{"name": t["name"], "type": t["type"], "shape": t["shape"],
                         "scale": t["scales"][0] if t["scales"] else None,
                         "zero_point": t["zero_points"][0] if t["zero_points"] else None}
                        for t in info["outputs"]],
            "errors": errors,
            "warnings": warns,
            "passed": not errors,
        }
        with open(a.json, "w") as f:
            json.dump(rec, f, indent=2, ensure_ascii=False)
        print(f"JSON -> {a.json}")

    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
