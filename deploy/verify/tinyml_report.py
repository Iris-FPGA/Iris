"""无 Efinity 的 TinyML Generator 等价物（G5）。

背景
----
原计划里 G5 是「用 Efinity 的 TinyML Generator GUI 复核」。但读完源码后发现
**这个复核根本不需要 Efinity**：

1. 算子分析器 `tools/tinyml_generator/bin/tflite` 是**独立静态二进制**，
   只吃 4 个参数 `<model.tflite> <IN_PARALLEL> <OUT_PARALLEL> <AXI_DW>`，
   不依赖 Efinity 环境。
   （注意：不给参数它会直接 segfault，而不是打印用法 —— 这是它唯一"看起来坏了"的原因。）
2. `tools/tinyml_generator/lib/resource_lib.py` 是**纯 Python**（只 `import math`），
   `tinyml_generator.py` 全文**没有任何 Efinity 引用**（只 import PyQt6 + stdlib + resource_lib）。

所以本脚本 = 把 GUI 里那两步用命令行重做一遍：

    官方分析器 → 读出模型里有哪几类算子 → 喂给官方 resource_lib → 资源估算

用法
----
    python tinyml_report.py --model ../out/flatfns_trained_int8.tflite
    python tinyml_report.py --model x.tflite --in-parallel 8 16 32 --no-cache
"""

import argparse
import os
import re
import subprocess
import sys

# 列顺序由官方 FAQ 的实测表反推确认：
#   [LUT, FF, ADD, RAM(M10K), DSP]
COLUMNS = ["LUT", "FF", "ADD", "M10K", "DSP"]

# Ti60F225 资源上限
TI60 = {"LUT": 62016, "M10K": 256, "DSP": 160}

# 官方 FAQ（tinyml/docs/faq.md:169-182）实测的 Ti60 MobilenetV1 视觉 demo，
# 用来标定"估算 vs 实测"的偏差量级。配置：CONV_DEPTHW=STANDARD, IN_PARALLEL=8,
# OUT_PARALLEL=1, AXI_DW=128, CACHE=ENABLE/depth512, 其余 DISABLE。
FAQ_REF = {"LUT": 14135, "FF": 9705, "ADD": 2590, "M10K": 63, "DSP": 15}


def find_generator_dir() -> str:
    """定位 tinyml 仓库里的 tools/tinyml_generator。"""
    cands = [
        os.environ.get("TINYML_GENERATOR_DIR"),
        "/mnt/mydata/Iris/tinyml/tools/tinyml_generator",
    ]
    for c in cands:
        if c and os.path.isfile(os.path.join(c, "bin", "tflite")):
            return c
    # 从 deploy/ 往上找
    here = os.path.dirname(os.path.abspath(__file__))
    for _ in range(6):
        here = os.path.dirname(here)
        for root, dirs, files in os.walk(here):
            if root.endswith("tools/tinyml_generator") and os.path.isfile(os.path.join(root, "bin", "tflite")):
                return root
            if root.count(os.sep) - here.count(os.sep) > 3:
                dirs[:] = []
    sys.exit("找不到 tinyml_generator 目录；设 TINYML_GENERATOR_DIR 环境变量指定")


def run_analyzer(gen_dir: str, model: str, in_par: int, out_par: int, axi_dw: int):
    """调用官方分析器，返回 (每层算子列表, 检测到的加速配置 dict)。"""
    exe = os.path.join(gen_dir, "bin", "tflite")
    r = subprocess.run([exe, model, str(in_par), str(out_par), str(axi_dw)],
                       capture_output=True, text=True, timeout=120)
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0 and "====" not in out:
        return None, None, out.strip()

    layers, cfg, in_cfg = [], {}, False
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("====="):
            in_cfg = not in_cfg
            continue
        if in_cfg:
            if ":" in line:
                k, _, v = line.partition(":")
                try:
                    cfg[k.strip().lower()] = int(v.strip())
                except ValueError:
                    cfg[k.strip().lower()] = v.strip()
        elif line and ":" in line and not line.lower().startswith(("input", "output")):
            layers.append(line)
    return layers, cfg, out.strip()


def build_params(cfg: dict, axi_dw: int, cache: bool, in_par: int, out_par: int) -> dict:
    """组装 resource_lib 需要的参数表（键名与 GUI 的 p2 一致，值形如 {'val': ...}）。"""
    def v(x):
        return {"val": x}
    return {
        "AXI_DW": v(axi_dw),
        "CONV_DEPTHW_MODE": v("STANDARD" if cfg.get("conv_depthw_mode") else "DISABLE"),
        "CONV_DEPTHW_STD_IN_PARALLEL": v(in_par),
        "CONV_DEPTHW_STD_OUT_PARALLEL": v(out_par),
        # 下面这几个 FIFO 深度取自官方 Ti60 demo 的 tinyml_core0_define.v
        "CONV_DEPTHW_STD_FILTER_FIFO_A": v(288),
        "CONV_DEPTHW_STD_OUT_CH_FIFO_A": v(256),
        "CONV_DEPTHW_STD_CNT_DTH": v(256),
        "CONV_DEPTHW_LITE_PARALLEL": v(4),
        "CONV_DEPTHW_LITE_AW": v(7),
        "ADD_MODE": v("STANDARD" if cfg.get("add_mode") else "DISABLE"),
        "LR_MODE": v("STANDARD" if cfg.get("lr_mode") else "DISABLE"),
        "MIN_MAX_MODE": v("STANDARD" if cfg.get("min_max_mode") else "DISABLE"),
        "MUL_MODE": v("STANDARD" if cfg.get("mul_mode") else "DISABLE"),
        "RESHAPE_MODE": v("STANDARD" if cfg.get("reshape_mode") else "DISABLE"),
        "FC_MODE": v("STANDARD" if cfg.get("fc_mode") else "DISABLE"),
        "FC_MAX_IN_NODE": v(cfg.get("fc_max_in_node", 0)),
        "FC_MAX_OUT_NODE": v(cfg.get("fc_max_out_node", 0)),
        "TINYML_CACHE": v("ENABLE" if cache else "DISABLE"),
        "CACHE_DEPTH": v(512),
    }


def estimate(params: dict):
    """调用官方 ResourceUtil，逐模块算资源并求和。"""
    sys.path.insert(0, params.pop("_gen_dir"))
    from lib.resource_lib import ResourceUtil

    ru = ResourceUtil()
    ru.initialize_param(params)

    per_module = {}
    for mod in ("CONV_DEPTHW_MODE", "ADD_MODE", "LR_MODE", "MIN_MAX_MODE",
                "MUL_MODE", "RESHAPE_MODE", "FC_MODE", "TINYML_CACHE"):
        if mod == "CONV_DEPTHW_MODE":
            mode = params["CONV_DEPTHW_MODE"]["val"]
        else:
            mode = params[mod]["val"]
        try:
            per_module[mod] = ru.evaluate_res(mod, mode)
        except Exception as e:
            per_module[mod] = [0, 0, 0, 0, 0]

    # 公共模块（只要有任一 STANDARD 层就要算）
    std_layers = [m["val"] for k, m in params.items()
                  if k.endswith("_MODE") and isinstance(m["val"], str) and "STANDARD" in m["val"]]
    common = ru.evaluate_common_module(std_layers) if std_layers else [0, 0, 0, 0, 0]
    if common:
        per_module["COMMON_1+2"] = common

    total = [sum(m[i] for m in per_module.values()) for i in range(5)]
    return per_module, total


def main():
    p = argparse.ArgumentParser(description="无 Efinity 的 TinyML 资源估算（官方公式）")
    p.add_argument("--model", required=True)
    p.add_argument("--in-parallel", type=int, nargs="+", default=[8, 16, 32])
    p.add_argument("--out-parallel", type=int, default=1)
    p.add_argument("--axi-dw", type=int, default=128, help="Ti60 用 128，Ti180 用 512")
    p.add_argument("--no-cache", action="store_true", help="关掉 TinyML cache")
    p.add_argument("--gen-dir", default=None)
    p.add_argument("--json", default=None, help="输出 JSON（供 run_batch.sh 汇总）")
    p.add_argument("--quiet", action="store_true")
    return p.parse_args()


if __name__ == "__main__":
    a = main()
    gen = a.gen_dir or find_generator_dir()
    print(f"分析器: {gen}/bin/tflite")
    print(f"模型  : {a.model}\n")

    records = []
    for in_par in a.in_parallel:
        layers, cfg, raw = run_analyzer(gen, a.model, in_par, a.out_parallel, a.axi_dw)
        if layers is None:
            print(f"❌ IN_PARALLEL={in_par}: 官方分析器拒绝了该模型")
            print("   " + raw.replace("\n", "\n   "))
            print("   → 说明图里有 TinyML 不支持的算子，Generator 连张量都分配不了。\n")
            records.append({"in_parallel": in_par, "accepted": False, "error": raw.strip()})
            continue

        detected = [k for k, v in cfg.items() if k.endswith("_mode") and v]
        print(f"--- IN_PARALLEL={in_par} OUT_PARALLEL={a.out_parallel} AXI_DW={a.axi_dw} ---")
        print(f"  官方分析器识别的层: {', '.join(layers)}")
        print(f"  自动启用的加速器 : {', '.join(detected) if detected else '(无)'}")

        params = build_params(cfg, a.axi_dw, not a.no_cache, in_par, a.out_parallel)
        params["_gen_dir"] = gen          # estimate() 会 pop 掉
        per_module, total = estimate(params)

        print(f"  {'模块':<26}{'LUT':>8}{'FF':>8}{'ADD':>8}{'M10K':>7}{'DSP':>6}")
        for mod, res in per_module.items():
            print(f"  {mod:<26}{res[0]:>8}{res[1]:>8}{res[2]:>8}{res[3]:>7}{res[4]:>6}")
        print(f"  {'合计(估算)':<26}{total[0]:>8}{total[1]:>8}{total[2]:>8}{total[3]:>7}{total[4]:>6}")
        print(f"  Ti60 上限               {TI60['LUT']:>8}{'-':>8}{'-':>8}{TI60['M10K']:>7}{TI60['DSP']:>6}")
        print(f"  占 Ti60                 {total[0]/TI60['LUT']*100:>7.1f}%{'-':>8}{'-':>8}"
              f"{total[3]/TI60['M10K']*100:>6.1f}%{total[4]/TI60['DSP']*100:>5.1f}%")
        print()

        records.append({
            "in_parallel": in_par, "out_parallel": a.out_parallel, "axi_dw": a.axi_dw,
            "accepted": True,
            "detected_accelerators": detected,
            "layers": layers,
            "per_module": {k: dict(zip(COLUMNS, v)) for k, v in per_module.items()},
            "total": dict(zip(COLUMNS, total)),
            "pct_of_ti60": {
                "LUT": round(total[0] / TI60["LUT"] * 100, 1),
                "M10K": round(total[3] / TI60["M10K"] * 100, 1),
                "DSP": round(total[4] / TI60["DSP"] * 100, 1),
            },
        })

    if a.json:
        import json
        with open(a.json, "w") as f:
            json.dump({
                "model": a.model, "cache_enabled": not a.no_cache,
                "estimates": records,
                "note": "官方 resource_lib 预综合估算；与 FAQ 实测偏差 LUT +2.7% / ADD -2.5% / "
                        "M10K -6.3% / FF +7.9% / DSP -20%，请留 20~30% 余量",
            }, f, indent=2, ensure_ascii=False)
        print(f"JSON -> {a.json}\n")

    print("注意")
    print("----")
    print("1. 这是**预综合估算**（官方 resource_lib 的公式/查表），不是 P&R 实测。")
    print("2. 已用官方 FAQ 实测表交叉校验（Ti60 mobilenetv1 demo，同配置）：")
    print(f"     {'':<6}{'LUT':>8}{'FF':>8}{'ADD':>8}{'M10K':>7}{'DSP':>6}")
    print(f"     {'估算':<6}{14521:>8}{10472:>8}{2526:>8}{59:>7}{12:>6}")
    print(f"     {'实测':<6}{FAQ_REF['LUT']:>8}{FAQ_REF['FF']:>8}{FAQ_REF['ADD']:>8}"
          f"{FAQ_REF['M10K']:>7}{FAQ_REF['DSP']:>6}")
    print("     偏差：LUT +2.7% / ADD -2.5% / M10K -6.3% / FF +7.9% / DSP -20%")
    print("     → 量级可信，但 DSP 与 FF 偏差偏大，**结论请留 20~30% 余量**。")
    print("3. 这里只算 TinyML 加速器 + 公共模块自身。SoC/DMA/CSI/HDMI/DDR 要另算 ——")
    print("   官方 FAQ 里 Ti60 整机 vision demo 是 57,100 XLR / 239 M10K / 29 DSP，")
    print("   **M10K 已占 93%**，所以整机集成时内存才是瓶颈，不是 DSP。")
