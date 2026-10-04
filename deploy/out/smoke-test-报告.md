# 转换环境冒烟测试报告

**日期**：2026-10-03
**目的**：验证新建的转换环境（`deploy/.venv`）能否跑通「队友的脚本 + 真实模型」，
并顺带取到第一个**算子合规证据**。
**执行**：`examples/fast_neural_style/script/model2tf_lite.py`，
模型 `model/one_last_kiss_style.model`，`--width 0.25 --size 256`，校准集 `images/calib`（90 张）。

---

## 1. 环境验证结果：通过

| 组件 | 版本 |
|---|---|
| python | 3.12.3 |
| tensorflow | 2.21.0（`TFLiteConverter` 可用） |
| onnx / onnxruntime | 1.20.1 / 1.26.0 |
| onnx2tf | 2.6.9（附带 `ai-edge-litert` 2.1.2） |
| torch / torchvision | 2.14.0+cpu / 0.29.0+cpu |
| numpy / pillow / cv2 / skimage | 2.2.6 / 12.3.0 / 4.13.0 / 0.26.0 |

步骤实测：

| 步骤 | 结果 |
|---|---|
| [1/5] `.model` → ONNX | ✅ `style.onnx` 446 KB |
| [2/5] ONNX vs PyTorch 数值校验 | ✅ **max abs diff = 0.000839** |
| [3/5] ONNX → tflite（onnx2tf） | ✅ `saved_model/style_float32.tflite`（460 KB） |
| [4/5] TF 全整数量化 | ❌ 见 §2 |
| [5/5] INT8 输出图 | 未执行（依赖 4/5） |

---

## 2. 队友脚本的两个问题（必须在正式用之前修）

### 2.1 `from_saved_model()` 已失效（阻塞性）

`model2tf_lite.py:93`：

```python
c = tf.lite.TFLiteConverter.from_saved_model(a.saved_model)   # ← 报错
```

```
OSError: SavedModel file does not exist at: saved_model/{saved_model.pbtxt|saved_model.pb}
```

**原因**：onnx2tf 2.6.9 的 `flatbuffer_direct` 模式**直接输出 `.tflite`**，
不再生成 `saved_model.pb`。输出目录里只有：

```
saved_model/style_float32.tflite
saved_model/style_float16.tflite
saved_model/schema_generated.py
saved_model/schema.fbs
saved_model/style_tensor_correspondence_report.json
```

实测加 `-osd`（`--output_signaturedefs`）**也不生成 SavedModel**。

**修法**（二选一）：
- **推荐**：不用 TF 的 converter，直接用 onnx2tf 自带的整数量化：
  ```
  onnx2tf -i style.onnx -o out -oiqt -ett full_integer_quant -cind <输入名> <校准数据...> -b 1
  ```
  （`-oiqt` 输出整数量化 tflite；`-ett full_integer_quant` 才是**全整数**，即 int8 进 int8 出）
- 或把 ONNX 另路转成 Keras/SavedModel 后再用 `TFLiteConverter`（图完全可控，作为 G2 门禁不过时的兜底）。

### 2.2 `subprocess.run(["onnx2tf", ...])` 依赖 PATH

用绝对路径调用 venv 的 python 时，`onnx2tf` 可执行文件不在 PATH 上 → `FileNotFoundError`。
修法：`PATH="$VENV/bin:$PATH"`，或改用 `sys.executable -m onnx2tf`。

### 2.3 默认 dtype 是 `uint8`，与 TinyML 不符

`model2tf_lite.py:21-22` 的 `--in-dtype/--out-dtype` 默认 `uint8`；
而 Efinix TinyML demo 与 `conv_drv()` 走的是 **int8**（`int8_t*`）。正式转换必须显式传 `int8`。

---

## 3. 关键证据：原模型算子严重不合规

对 `style_float32.tflite` 用 `tf.lite.Interpreter._get_ops_details()` 统计：

| 算子 | 个数 | 在 TinyML 白名单内？ |
|---|---:|---|
| `CONV_2D` | 16 | ✅ |
| `ADD` | 35 | ✅ |
| `MUL` | 45 | ✅ |
| **`MIRROR_PAD`** | **16** | ❌ ← 来自 `ReflectionPad2d` |
| **`MEAN`** | **30** | ❌ ← 来自 `InstanceNorm2d` |
| **`SUB`** | **15** | ❌ |
| **`SQRT`** | **15** | ❌ |
| **`DIV`** | **15** | ❌ |
| **`RESIZE_NEAREST_NEIGHBOR`** | **2** | ❌ ← 来自 `nearest×2` 上采样 |
| `DELEGATE` | 16 | — XNNPACK 委托的统计项，非 flatbuffer 算子 |

**结论**：7 类、93 个算子会掉回 RISC-V 软件执行。

这**实测验证**了 `Iris/docs/风格迁移_模型核对与FPGA方案.md` 第二节的算子缺口判断，
也**实测否证**了"直接拿现有 `.model` 转 tflite 就能上 TinyML"的想法。

对照 `deploy/` 计划里的 §1 算子改造表：

| 现在的算子 | 改造后应该变成 |
|---|---|
| `MIRROR_PAD` ×16 | **消失**（`Conv2d(padding=...)` 的 SAME 零填充吸收） |
| `MEAN`/`SUB`/`SQRT`/`DIV` ×75 | **消失**（`InstanceNorm2d` → `BatchNorm2d`，eval 时折叠进 Conv） |
| `RESIZE_NEAREST_NEIGHBOR` ×2 | **消失**（改为单分辨率全卷积，×N 放大交给显示侧硬件） |
| `ADD` ×35 / `CONV_2D` ×16 / `MUL` ×45 | 保留（`ADD`/`MUL`/`CONV_2D` 都在白名单） |

> 即：改造后目标图应只剩 **`CONV_2D` + `ADD`**（可能有个别 `MUL`）。

---

## 4. 复现命令

```bash
source /mnt/mydata/Iris/deploy/.venv/bin/activate
cd /mnt/mydata/Iris/deploy/out
PATH=$(dirname $(which python)):$PATH python \
  /mnt/mydata/Iris/examples/fast_neural_style/script/model2tf_lite.py \
  --model /mnt/mydata/Iris/examples/fast_neural_style/model/one_last_kiss_style.model \
  --width 0.25 --size 256 \
  --calib /mnt/mydata/Iris/examples/fast_neural_style/images/calib \
  --in-dtype int8 --out-dtype int8 \
  --int8-tflite smoke_ol_kiss_int8.tflite
```

产物：`style.onnx`、`saved_model/style_float32.tflite`、`out_osd/`。
