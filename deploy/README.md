# deploy/ —— TinyML 算子合规工具链

> 目标：把风格迁移的 PyTorch `.model` 变成 **Efinix TinyML 真正能加速的 INT8 `.tflite`**。
>
> 本文是这套工具链的入口。背景见 `docs/风格迁移_模型核对与FPGA方案.md`
> 与 `docs/TinyML模型训练量化与Ti60F225部署计划.md`。

---

## 一句话结论

`docs/风格迁移_模型核对与FPGA方案.md` 第二节判定"放弃 TFLite / 官方 TinyML 路线"，
理由是 `ReflectionPad2d` / `InstanceNorm2d` / `nearest×2` 三个算子不在加速集内。

**实测结论：不是路线不可行，是原网络不可用。** 这三个算子都能在训练脚本里从架构上设计掉，
改造后算子从 **93 个非白名单** 降到 **0**。

| | 原版（现有 `.model` 转出） | 改造后 FlatFNS |
|---|---|---|
| 算子 | `CONV_2D×16, ADD×35, MUL×45,`<br>`MIRROR_PAD×16, MEAN×30, SUB×15, SQRT×15, DIV×15,`<br>`RESIZE_NEAREST_NEIGHBOR×2` | **`CONV_2D×8, ADD×3`** |
| 非白名单算子 | **93 个 / 7 类** | **0** |
| 输入/输出 | `FLOAT32` | **`INT8`** |
| 体积 | 466.6 KB | **22.0 KB** |
| 参数量 | 108,771 | 14,803（权重 14,688） |

**厂商工具自己的判定**（`tinyml/tools/tinyml_generator/bin/tflite`，无需 Efinity）：

- 改造后模型 → 自动启用 `conv_depthw_mode` + `add_mode`，`input type: 9`(INT8) ✅
- 原版模型 → `Didn't find op for builtin opcode 'DIV'` → `AllocateTensors() failed` ❌

---

## 算子改造（核心）

| 原结构 | 改成 | 消除的算子 |
|---|---|---|
| `ReflectionPad2d` + Conv | `Conv2d(padding=k//2)` 零填充 | `MIRROR_PAD`（零填充被 `CONV_2D` 的 SAME 吸收，**不产生算子**） |
| `InstanceNorm2d(affine)` | `BatchNorm2d` + **导出前折叠进卷积** | `MEAN/SUB/SQRT/DIV`（BN 可离线折叠，**折叠后零算子**） |
| `nearest×2` + Conv（deconv 块） | **删掉**，整网单分辨率全卷积 | `RESIZE_NEAREST_NEIGHBOR`（放大交给显示侧硬件） |
| 独立 `ReLU` 层 | ReLU 紧贴 Conv+BN | 独立 `RELU`（被 TFLite 融合进 `CONV_2D`） |

**保留** `CONV_2D`（卷积）与 `ADD`（残差）—— 两者都在白名单，
且 `add_drv()` 签名带 `input1/2_multiplier+shift+offset`，说明残差两端量化参数不同也能加速。

> 白名单依据：`tinyml/tools/tinyml_generator/README.md`（Supported layers）
> + `tinyml/.../src/platform/tinyml/ops/` 目录（只有 conv/depthwise/add/mul/lr/maxmin/reshape/fully_connected 八个驱动）。

顺带修掉的两个**跑不起来**的 bug（见 `train/改动说明.md`）：
1. `PIL.Image.ANTIALIAS` 在 Pillow ≥ 10 已移除 → `AttributeError`
2. `normalize_batch` 用 `div_` 原地改张量，在 `y = transformer(x)` 之后执行 → autograd 报
   `modified by an inplace operation`

---

## 目录结构

```
deploy/
├── train/           训练侧
│   ├── flatfns_model.py    算子合规的网络（含档位算力表，直接 python 跑会打印）
│   ├── train.py            改自 fast_neural_style/neural_style.py（损失函数原样保留）
│   ├── export_onnx.py      fold BN → ONNX，含 G1 门禁；支持非方形 --size 160x120
│   ├── utils.py/vgg.py     自包含（含上面两个 bug 的修复）
│   └── 改动说明.md         逐条改动清单 + 复现命令
├── quant/
│   └── to_tflite.py        ONNX → SavedModel → **全整数 INT8** tflite
├── verify/           门禁
│   ├── ops_inventory.py    G2/G3：直接解析 flatbuffer（算子白名单 + builtin version + dtype）
│   ├── check_equiv.py      G4：INT8 vs FP32 的 PSNR/SSIM
│   └── tinyml_report.py    G5：**无需 Efinity** 的 TinyML Generator 等价物
├── env/              环境
│   ├── setup-convert-env.sh   一键建本机转换环境（幂等）
│   └── requirements-*.txt     转换环境 / 云训练环境
├── cloud/            算力自由（gpufree.cn）跑批
│   ├── 运行手册.md          逐步操作清单（含"无卡模式开机先做准备"）
│   ├── bootstrap.sh         云上环境自检 + 拉素材 + 生成 env.sh
│   ├── run_batch.sh         训练→导出→量化→门禁→资源估算→精度→样图，汇总 results.csv
│   ├── configs.tsv          实验矩阵
│   ├── make_subset.py       COCO 子集抽取（硬链接，不占额外磁盘）
│   └── pack.sh              打包成 ~43 KB 的 deploy_code.tar.gz
├── scripts/
│   └── install-efinity.sh   装 Efinity（解压式，默认 /mnt/mydata/efinity）
└── out/              参考产物（可重新生成）
```

---

## 快速开始

### 本机（转换 + 合规校验，CPU 足够）

```bash
deploy/env/setup-convert-env.sh
source deploy/.venv/bin/activate

python deploy/train/export_onnx.py --weights <某.model> --out out/x.onnx --size 160x120
python deploy/quant/to_tflite.py --onnx out/x.onnx --calib <校准图目录> \
       --out out/x_int8.tflite --keep-float-tflite
python deploy/verify/ops_inventory.py --model out/x_int8.tflite --report out/compliance.md
python deploy/verify/tinyml_report.py --model out/x_int8.tflite --in-parallel 8 16 32
```

### 云上（训练）

见 `cloud/运行手册.md`。三条命令：

```bash
deploy/cloud/pack.sh                      # 本机，产出 43 KB
deploy/cloud/bootstrap.sh --dataset ...   # 云上，一次性
deploy/cloud/run_batch.sh --smoke         # 先验证链路，再跑全网格
```

---

## 门禁一览

| 门禁 | 内容 | 工具 | 结果 |
|---|---|---|---|
| G1 | ONNX 图算子 ⊆ {Conv, Add, Relu} | `train/export_onnx.py` | ✅ `{Conv:8, Relu:4, Add:3}` |
| G2 | tflite 算子 ⊆ 9 项 TinyML 白名单 | `verify/ops_inventory.py` | ✅ `{CONV_2D:8(v3), ADD:3(v2)}` |
| G3 | schema=3；输入/输出 INT8；per-channel 权重 | 同上 | ✅ |
| G4 | INT8 vs FP32 的 PSNR/SSIM | `verify/check_equiv.py` | ✅（1 epoch 冒烟模型，数字偏乐观，见下） |
| G5 | 厂商工具复核 + 资源估算 | `verify/tinyml_report.py`（**不需要 Efinity**） | ✅ |

`ops_inventory.py` 是**反证过**的：对原版模型报 8 项违规并 exit 1，不是橡皮章。

### 资源估算（Ti60F225：62,016 LUT / 256 M10K / 160 DSP）

用官方 `resource_lib.py`（纯 Python，无 Efinity 依赖）算，并用官方 FAQ 实测表标定
（偏差 LUT +2.7% / ADD −2.5% / M10K −6.3% / FF +7.9% / DSP −20%）：

| IN_PARALLEL | LUT | M10K | DSP |
|---|---:|---:|---:|
| 8 | 16,112 (26%) | 59 (23%) | 20 (12.5%) |
| 16 | 16,992 (27.4%) | 65 (25.4%) | 28 (17.5%) |
| 32 | 18,752 (30.2%) | 77 (30.1%) | 44 (27.5%) |

**加速器面积只由并行度决定，与模型大小无关** —— 模型做大只涨时间不涨面积。

---

## 状态

**已完成**：算子合规链路全通、四道门禁 + 厂商工具复核通过、跑批脚本本机验证过。

**未做 / 注意**：

- `out/` 里的模型只训了 **90 张图 / 1 epoch**（本地 CPU 冒烟），**画质无意义**，
  G4 的 60 dB 偏乐观 —— 它证明的是量化链路忠实，不是画质。真训练在云上。
- **`style_weight` 必须重扫**：IN 换 BN 后风格强度会变，原来的 `1e10` 不能直接沿用。
- Efinity 未安装；但本文所有工作**都不需要它**（只有编译比特流/上板才需要）。
