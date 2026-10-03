#!/usr/bin/env bash
# 云上批次实验：对 configs.tsv 里每一行跑完整链路
#
#     训练 → 导出 ONNX(G1) → INT8 量化 → 算子门禁(G2/G3) → 资源估算(G5) → 精度对比(G4) → 风格化样图
#
# 结果汇总到 <out>/results.csv。单个配置失败不会中断整批（逐行记录状态）。
#
# 用法：
#   deploy/cloud/run_batch.sh --smoke              # 先验证云上环境链路（1 个配置、1 epoch）
#   deploy/cloud/run_batch.sh                      # 跑 configs.tsv 全部
#   deploy/cloud/run_batch.sh --only c16b3         # 只跑名字匹配的
#   deploy/cloud/run_batch.sh --force              # 重跑已完成的
#
# 前置：先跑过 bootstrap.sh（会生成 env.sh，本脚本自动 source）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$HERE/env.sh" ]] && source "$HERE/env.sh"

DEPLOY_ROOT="${DEPLOY_ROOT:-$(cd "$HERE/.." && pwd)}"
PY="${PY:-python3}"
CONFIGS="$HERE/configs.tsv"
OUT="${DATA_DIR:-$DEPLOY_ROOT}/runs/batch"
SIZE=128                # 导出/量化用的部署分辨率
ACCEL=1
FORCE=0
SMOKE=0
ONLY=""
LIMIT=0
CONTENT=""
RES_IN_PARALLEL=16   # 资源估算用哪个 IN_PARALLEL 报进 results.csv

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configs) CONFIGS="$2"; shift 2 ;;
        --out)     OUT="$2"; shift 2 ;;
        --size)    SIZE="$2"; shift 2 ;;
        --only)    ONLY="$2"; shift 2 ;;
        --limit)   LIMIT="$2"; shift 2 ;;
        --content) CONTENT="$2"; shift 2 ;;
        --res-in-parallel) RES_IN_PARALLEL="$2"; shift 2 ;;
        --dataset) DATASET="$2"; shift 2 ;;
        --no-accel) ACCEL=0; shift ;;
        --force)   FORCE=1; shift ;;
        --smoke)   SMOKE=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

# onnx2tf 是可执行文件，必须在 PATH 上（队友脚本在这一点上也踩过坑）
export PATH="$(dirname "$("$PY" -c 'import sys;print(sys.executable)')"):$PATH"
export TORCH_HOME="${TORCH_HOME:-${DATA_DIR:-$DEPLOY_ROOT}/.torch}"

: "${STYLE_IMAGE:?env.sh 未生成或缺少 STYLE_IMAGE，请先跑 deploy/cloud/bootstrap.sh}"
: "${CALIB_DIR:?env.sh 缺少 CALIB_DIR}"
: "${DATASET:?env.sh 缺少 DATASET，用 --dataset 指定，或重跑 bootstrap.sh --dataset ...}"

[[ -f "$STYLE_IMAGE" ]] || { echo "找不到风格图 $STYLE_IMAGE" >&2; exit 1; }
[[ -d "$CALIB_DIR" ]]   || { echo "找不到校准目录 $CALIB_DIR" >&2; exit 1; }
[[ -d "$DATASET" ]]     || { echo "找不到训练集 $DATASET" >&2; exit 1; }
# 默认拿第一张校准图做精度对比的输入
[[ -z "$CONTENT" ]] && CONTENT="$(find "$CALIB_DIR" -maxdepth 1 -name '*.jpg' | sort | head -1)"

mkdir -p "$OUT" "$OUT/runs" "$OUT/logs"
echo "输出目录 : $OUT"
echo "训练集   : $DATASET"
echo "风格图   : $STYLE_IMAGE"
echo "校准集   : $CALIB_DIR"
echo "精度输入 : $CONTENT"
echo

run_one() {
    local name="$1" C="$2" N="$3" K="$4" E="$5" IMG="$6" BS="$7" LR="$8" SW="$9" CW="${10}"
    local rdir="$OUT/runs/$name" log="$OUT/logs/$name.log"
    local t0 t1

    if [[ -f "$rdir/STATUS" && "$FORCE" != "1" ]]; then
        echo "  ⏭  $name 已完成（--force 可重跑）"
        return 0
    fi
    mkdir -p "$rdir"
    : > "$log"
    echo "  ▶  $name  (C=$C N=$N k=$K epochs=$E img=$IMG bs=$BS lr=$LR style_w=$SW)"
    t0=$(date +%s)

    local accel_flag=""
    [[ "$ACCEL" == "1" ]] && accel_flag="--accel"

    {
        echo "===== [1/7] 训练 ====="
        "$PY" "$DEPLOY_ROOT/train/train.py" train \
            --dataset "$DATASET" --style-image "$STYLE_IMAGE" \
            --save-model-dir "$rdir" \
            --epochs "$E" --channels "$C" --blocks "$N" --kernel-size "$K" \
            --image-size "$IMG" --batch-size "$BS" --lr "$LR" \
            --style-weight "$SW" --content-weight "$CW" --log-interval 200 \
            $accel_flag
    } >>"$log" 2>&1
    local model
    model="$(ls -t "$rdir"/*.model 2>/dev/null | head -1)"
    if [[ -z "$model" ]]; then
        echo "FAILED_TRAIN" > "$rdir/STATUS"; echo "  ❌ 训练失败（看 $log）"; return 1
    fi
    echo "     模型 $(basename "$model")"

    {
        echo "===== [2/7] 导出 ONNX（含 G1 门禁）====="
        "$PY" "$DEPLOY_ROOT/train/export_onnx.py" --weights "$model" \
            --out "$OUT/$name.onnx" --channels "$C" --blocks "$N" \
            --kernel-size "$K" --size "$SIZE"
    } >>"$log" 2>&1
    if [[ ! -f "$OUT/$name.onnx" ]]; then
        echo "FAILED_ONNX" > "$rdir/STATUS"; echo "  ❌ ONNX 导出/G1 失败（看 $log）"; return 1
    fi

    {
        echo "===== [3/7] INT8 量化 ====="
        "$PY" "$DEPLOY_ROOT/quant/to_tflite.py" --onnx "$OUT/$name.onnx" \
            --calib "$CALIB_DIR" --out "$OUT/${name}_int8.tflite" --keep-float-tflite
    } >>"$log" 2>&1
    if [[ ! -f "$OUT/${name}_int8.tflite" ]]; then
        echo "FAILED_QUANT" > "$rdir/STATUS"; echo "  ❌ 量化失败（看 $log）"; return 1
    fi

    echo "===== [4/7] 算子门禁 G2/G3 =====" >>"$log"
    "$PY" "$DEPLOY_ROOT/verify/ops_inventory.py" \
        --model "$OUT/${name}_int8.tflite" \
        --report "$OUT/${name}_compliance.md" \
        --json "$OUT/${name}.gate.json" >>"$log" 2>&1
    local gate=$?
    if [[ "$gate" != "0" ]]; then
        echo "FAILED_GATE" > "$rdir/STATUS"; echo "  ❌ 算子门禁未通过（看 $OUT/${name}_compliance.md）"
    else
        echo "     ✅ 门禁通过"
    fi

    echo "===== [5/7] 资源估算 G5（官方 resource_lib，无需 Efinity）=====" >>"$log"
    "$PY" "$DEPLOY_ROOT/verify/tinyml_report.py" \
        --model "$OUT/${name}_int8.tflite" \
        --in-parallel "$RES_IN_PARALLEL" \
        --json "$OUT/${name}.resource.json" >>"$log" 2>&1

    echo "===== [6/7] 精度对比 G4 =====" >>"$log"
    "$PY" "$DEPLOY_ROOT/verify/check_equiv.py" \
        --int8 "$OUT/${name}_int8.tflite" \
        --float "$OUT/${name}_int8_float32.tflite" \
        --torch-model "$model" --channels "$C" --blocks "$N" \
        --content "$CONTENT" --json "$OUT/${name}.equiv.json" >>"$log" 2>&1

    echo "===== [7/7] 风格化样图 =====" >>"$log"
    "$PY" "$DEPLOY_ROOT/train/train.py" eval \
        --content-image "$CONTENT" --model "$model" \
        --output-image "$OUT/${name}_stylized.jpg" \
        --channels "$C" --blocks "$N" --kernel-size "$K" $accel_flag >>"$log" 2>&1

    t1=$(date +%s)
    echo "$((t1 - t0))" > "$rdir/SECONDS"
    [[ "$gate" == "0" ]] && echo "OK" > "$rdir/STATUS" || echo "GATE_FAIL" > "$rdir/STATUS"
    echo "     完成，用时 $((t1 - t0))s"
    return 0
}

# ---- 读出配置 ----
mapfile -t ROWS < <(grep -vE '^\s*#|^\s*$' "$CONFIGS")
[[ "$SMOKE" == "1" ]] && ROWS=("${ROWS[0]}")
[[ "$LIMIT" -gt 0 ]] && ROWS=("${ROWS[@]:0:$LIMIT}")

total=0; failed=0
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r name C N K E IMG BS LR SW CW <<< "$row"
    [[ -z "${name:-}" ]] && continue
    # 跳过表头等非法行（例如表头忘了用 # 注释掉）
    if ! [[ "$C" =~ ^[0-9]+$ && "$N" =~ ^[0-9]+$ && "$E" =~ ^[0-9]+$ ]]; then
        echo "  ⏭  跳过非法配置行: $row"
        continue
    fi
    if [[ -n "$ONLY" && ! "$name" =~ $ONLY ]]; then continue; fi
    if [[ "$SMOKE" == "1" ]]; then
        name="${name}_smoke"; E=1; IMG=64; BS=2      # 冒烟：1 epoch、小图、小 batch
        echo "冒烟模式：$name  (epochs=$E image_size=$IMG batch=$BS)"
    fi
    total=$((total + 1))
    run_one "$name" "$C" "$N" "${K:-3}" "$E" "$IMG" "$BS" "$LR" "$SW" "$CW" || failed=$((failed + 1))
    echo
done

echo "==> 汇总"
"$PY" - "$OUT" <<'PYCODE'
import csv, glob, json, os, sys
out = sys.argv[1]
rows, names = [], set()
for g in sorted(glob.glob(os.path.join(out, "*.gate.json"))):
    names.add(os.path.basename(g)[:-len(".gate.json")])
for d in sorted(glob.glob(os.path.join(out, "runs", "*"))):
    if os.path.isdir(d):
        names.add(os.path.basename(d))

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {}

hdr = ["name", "channels", "blocks", "params", "macs_per_px", "epochs", "seconds",
       "non_whitelisted_ops", "gate",
       "res_lut", "res_m10k", "res_dsp", "res_in_parallel",
       "psnr_quant_db", "ssim_quant",
       "psnr_e2e_db", "ssim_e2e", "tflite_kb", "status"]
w = csv.writer(open(os.path.join(out, "results.csv"), "w", newline=""))
w.writerow(hdr)

print(f"{'name':<22}{'C':>3}{'N':>3}{'params':>9}{'门禁':>6}"
      f"{'LUT':>8}{'M10K':>6}{'DSP':>5}{'PSNR':>8}{'KB':>7}{'秒':>7}  status")
print("-" * 100)
for n in sorted(names):
    cfg = load(os.path.join(out, "runs", n, "train_config.json"))
    gate = load(os.path.join(out, n + ".gate.json"))
    eq = load(os.path.join(out, n + ".equiv.json"))
    res = load(os.path.join(out, n + ".resource.json"))
    est = (res.get("estimates") or [{}])[0]
    rtot = est.get("total", {}) if est.get("accepted") else {}
    sec = ""
    try:
        sec = open(os.path.join(out, "runs", n, "SECONDS")).read().strip()
    except Exception:
        pass
    status = ""
    try:
        status = open(os.path.join(out, "runs", n, "STATUS")).read().strip()
    except Exception:
        pass
    m = eq.get("metrics", {})
    q = m.get("quant_only", {}) or {}
    e2e = m.get("end_to_end", {}) or {}
    kb = round(gate.get("size_bytes", 0) / 1024, 1) if gate else ""
    gtxt = "通过" if gate.get("passed") else ("未通过" if gate else "-")
    p = f"{q.get('psnr_db'):.1f}" if q.get("psnr_db") else "-"
    s = f"{q.get('ssim'):.4f}" if q.get("ssim") else "-"
    rl, rm, rd = rtot.get("LUT", ""), rtot.get("M10K", ""), rtot.get("DSP", "")
    w.writerow([n, cfg.get("channels", ""), cfg.get("blocks", ""),
                cfg.get("num_weight_params", ""), cfg.get("macs_per_pixel", ""),
                cfg.get("epochs", ""), sec,
                gate.get("non_whitelisted_total", ""), gtxt,
                rl, rm, rd, est.get("in_parallel", "") if rtot else "",
                q.get("psnr_db"), q.get("ssim"), e2e.get("psnr_db"), e2e.get("ssim"),
                kb, status])
    print(f"{n:<22}{str(cfg.get('channels','')):>3}{str(cfg.get('blocks','')):>3}"
          f"{str(cfg.get('num_weight_params','')):>9}{gtxt:>6}"
          f"{str(rl):>8}{str(rm):>6}{str(rd):>5}{p:>8}{str(kb):>7}{sec:>7}  {status}")
print("-" * 100)
print(f"results.csv -> {os.path.join(out, 'results.csv')}")
print("样图： <out>/<name>_stylized.jpg    合规报告： <out>/<name>_compliance.md")
print("注：LUT/M10K/DSP 是官方 resource_lib 的**预综合估算**（IN_PARALLEL 见 CSV 的 res_in_parallel 列），")
print("    与官方 FAQ 实测偏差最大 -20%，做决策请留 20~30% 余量。")
PYCODE

echo
echo "==> 结束：共 $total 个配置，失败 $failed 个"
echo "    日志 $OUT/logs/   结果 $OUT/results.csv"
[[ "$failed" -gt 0 ]] && exit 1 || exit 0
