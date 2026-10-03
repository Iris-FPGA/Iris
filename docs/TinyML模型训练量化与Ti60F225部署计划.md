# TinyML 模型训练、INT8 量化与 Ti60F225 部署计划

> 目标：在 Efinix Titanium **Ti60F225I3** 开发板上运行风格迁移模型。
>
> 约束：训练得到的 PyTorch `.model` 不能直接交给硬件；必须经过图转换、全整数量化，得到 `int8` 的 `.tflite`，再使用 Efinix TinyML Generator 生成硬件定义和软件模型数据。
>
> 适用仓库：
> - [FinResect/examples](https://github.com/FinResect/examples)，重点查看 `main` 与 `Iris` 分支的 `fast_neural_style`。
> - [Efinix-Inc/tinyml](https://github.com/Efinix-Inc/tinyml)，使用与 Efinity 版本匹配的 release/tag。

## 1. 总体结论

完整链路如下：

```text
训练数据/风格图
    -> PyTorch 训练
    -> checkpoint.model（state_dict，仅中间产物）
    -> ONNX
    -> TensorFlow SavedModel
    -> float TFLite（转换检查用）
    -> full integer INT8 TFLite
    -> TinyML Generator
    -> tinyml_core0_define.v + model_data.cc/.h
    -> Ti60F225 TinyML 工程
    -> TFLite Micro 软件推理
    -> 逐步启用 TinyML 硬件加速器
    -> 摄像头/DDR/HDMI 实时系统
```

推荐同时维护两条路线：

1. **验证路线**：先把现有风格迁移模型转成 INT8 `.tflite`，验证 PC、TFLite Micro、TinyML Generator 和板端工程的完整链路。
2. **性能路线**：重训 TinyML 友好网络，减少不被硬件加速的算子，并根据 Ti60F225I3 的 DSP、片上 RAM 和时序结果调整通道数、输入分辨率和并行度。

当前模型可以用来验证流程，但不应直接作为最终实时性能方案。

## 2. 两个 examples 分支的差异

### 2.1 `main` 分支

`main` 是原始 PyTorch fast-neural-style 示例，主要包含：

- 原版 `TransformerNet`，通道为 `32/64/128`；
- PyTorch 训练和图片风格化推理；
- 输出为 PyTorch `state_dict`，通常文件后缀是 `.model`。

它没有针对 Ti60/TinyML 的通道缩放和 TFLite 转换脚本。

### 2.2 `Iris` 分支

`Iris` 分支增加了：

- `TransformerNet(width=...)`；
- `--width 0.25` 的四分之一通道模型，通道为 `8/16/32`；
- 校准图目录；
- `fast_neural_style/script/model2tf_lite.py`；
- 中文使用说明和导出参数。

现有转换脚本实现的是：

```text
.model -> ONNX -> onnx2tf/SavedModel -> INT8 TFLite
```

但它不会自动把模型改造成 Efinix TinyML 硬件完全友好的网络，也不会替用户完成板端工程、内存和时序验证。因此需要在转换前修改模型结构，并在转换后分析 TFLite 算子。

## 3. 当前模型的算子问题

当前 `width=0.25` 风格迁移网络大致包含：

- 16 个普通卷积；
- 15 个 `InstanceNorm2d`；
- 10 个 `ReLU`；
- 5 个残差 `ADD`；
- 2 个最近邻 `×2` 上采样；
- `ReflectionPad2d`；
- 输出裁剪/饱和处理。

### 3.1 Efinix TinyML Generator 的硬件加速层

官方 Generator 支持的硬件加速层为：

- `CONV_2D`；
- `DEPTHWISE_CONV_2D`；
- `FULLY_CONNECTED`；
- `ADD`；
- `MUL`；
- `MINIMUM/MAXIMUM`；
- `LEAKY_RELU`；
- `RESHAPE`。

参考：

- [TinyML Generator README](https://github.com/Efinix-Inc/tinyml/blob/main/tools/tinyml_generator/README.md)
- [TinyML FAQ](https://github.com/Efinix-Inc/tinyml/blob/main/docs/faq.md)

这里的“支持”是指可以映射到 Efinix TinyML Accelerator；TFLite Micro 软件本身还可能支持其他算子，但这些算子会由 RISC-V 软件执行，不能按硬件加速性能估算。

### 3.2 算子改造表

| 当前结构 | 建议修改 | 目的 |
|---|---|---|
| `Conv2D` | 保留 | 映射到 `CONV_2D` 硬件加速器 |
| 残差相加 | 保留 | 映射到 `ADD` 硬件加速器 |
| `InstanceNorm2d` | 改为 `BatchNorm2d`，训练后折叠进卷积 | 避免 `MEAN/RSQRT/SUB/MUL/ADD` 链 |
| `ReflectionPad2d + Conv2D` | 改为带普通 `padding` 的 `Conv2D` | 避免 `PAD/MIRROR_PAD` 进入关键路径 |
| `ReLU` | 改为 `LeakyReLU(alpha=0.01)`，导出后确认确实生成 `LEAKY_RELU` | 使用官方支持的激活硬件 |
| 最近邻上采样 | 第一版保留为软件算子；后续可做独立预处理硬件 | Generator 没有 `RESIZE_NEAREST` 加速配置 |
| 输出 `clamp` | 用 `MINIMUM/MAXIMUM`，或在显示链路中裁剪 | 使输出稳定在 RGB 量化范围 |

`RESIZE_NEAREST`、`PAD`、`MEAN`、`RSQRT` 等即使能被 TFLite Micro 解析，也不应假设会被 TinyML Accelerator 加速。

## 4. Ti60F225I3 资源约束

本板为 Efinix Titanium **Ti60F225I3**。本地资料中的关键资源如下：

| 资源 | 规模 | 对模型的影响 |
|---|---:|---|
| Logic Elements | 约 62,016 | SoC、视频链路、控制和加速器共用 |
| DSP | 160 | 卷积 MAC 的主要资源 |
| 片上 RAM | 256 × 10 Kbit，约 327 KB | 行缓存、FIFO、权重缓存和 TinyML 本身共用 |
| 外部 DDR3 | 16 bit，理论约 1.6 GB/s | 帧缓存和较大中间特征图使用 |
| MIPI | I3 等级最高约 1.5 Gbps/lane | SC431HAI CSI-2 输入 |
| 速度等级 | I3 | Efinity 工程使用 Ti60F225/I3 timing model |

重要事项：

- “INT8 权重小于 500 KB”不等于“可以全部放在片上 RAM”；TinyML Accelerator、DMA、SoC、视频 IP 会先消耗资源。
- Generator 的资源估算只能作为起点，最终以 Efinity P&R 报告、DSP/RAM 使用率和 timing report 为准。
- MIPI 使用时确认开发板 J2/J3 为 **1.2 V**。
- 新建工程时使用 SystemVerilog 2009，TinyML Accelerator 源码依赖该语法版本。

已有本地参考文档：

- [Ti60F225 DemoBoard 用户手册](./Ti60F225_DemoBoard_v4_用户手册.md)
- [实时绘画任务分级与硬件实现分析](./赛题一_实时绘画_任务分级与硬件实现分析.md)
- [风格迁移模型核对与 FPGA 方案](./风格迁移_模型核对与FPGA方案.md)

## 5. 模型修改方案

新增一个独立的 TinyML 版本网络，例如 `TransformerNetTinyML`，不要覆盖原始 `TransformerNet`。第一版建议：

```text
输入 RGB 256×256
  -> Conv2D(padding) + BatchNorm2d + LeakyReLU
  -> Conv2D(stride=2) + BatchNorm2d + LeakyReLU
  -> Conv2D(stride=2) + BatchNorm2d + LeakyReLU
  -> 5 个残差块（Conv + BN + LeakyReLU + Conv + BN + Add）
  -> 最近邻上采样 + Conv + BN + LeakyReLU
  -> 最近邻上采样 + Conv + BN + LeakyReLU
  -> Conv2D
  -> 输出裁剪
```

建议先使用 `width=0.25`，即 `8/16/32` 通道；如果画质不足，再测试 `width=0.5`。

### 5.1 BN folding

部署前将 BatchNorm 折叠到相邻卷积：

```text
scale = gamma / sqrt(var + epsilon)
W_fold = W * scale
b_fold = (b - mean) * scale + beta
```

折叠后应从导出图中消除 BatchNorm 节点，减少非硬件算子和中间张量。

### 5.2 输入和输出约定

训练脚本当前使用 RGB `0~255`，不是 ImageNet 的 `0~1` 或均值方差归一化。部署时必须统一：

- 摄像头 RGB888 → 模型输入量化；
- 模型输出反量化 → `clamp(0, 255)` → RGB/HDMI；
- 量化参数从 `.tflite` 读取，不要固定假设 zero point 为 `-128` 或 `128`。

## 6. 训练阶段计划

### P0：小样本冒烟

目标是确认网络可以训练、保存、加载和推理。

1. 准备 20～100 张内容图和 1 张风格图。
2. 用 `width=0.25`、1 个 epoch 跑通。
3. 保存 checkpoint，并立即加载测试。
4. 检查输出尺寸、数值范围和是否出现 NaN/Inf。

### P1：TinyML 友好网络训练

1. 使用 `BatchNorm2d`、普通 padding、`LeakyReLU` 版本。
2. 用真实摄像头内容或 COCO 子集训练。
3. 保存训练配置、随机种子、数据集版本和风格图。
4. 用原始 InstanceNorm 版本作为画质基线。
5. 对比内容保真度、风格强度、边缘伪影和颜色溢出。

### P2：使用算力账号进行完整训练

算力账号适合用于：

- COCO/实际内容数据集的完整训练；
- `width=0.25/0.5` 对比实验；
- PTQ 与 QAT 对比；
- 量化校准集和输入分辨率的网格实验。

每次实验至少记录：

```text
model_width
input_size
epochs
batch_size
learning_rate
content_weight/style_weight
checkpoint hash
验证集画质指标
模型参数量和文件大小
```

## 7. PyTorch 到 INT8 TFLite

### 7.1 转换环境

建议将训练环境与转换环境分离：

- 训练：PyTorch、torchvision、GPU 环境；
- 转换：Python 3.10/3.11、TensorFlow、onnx、onnxruntime、onnx2tf、Pillow；
- 板端：Efinity、Efinity RISC-V Embedded Software IDE、TinyML 工程。

不要因为训练环境能加载 `.model`，就认为它能够运行 TensorFlow/TFLite Converter。

### 7.2 现有脚本的验证命令

`examples/Iris` 的脚本可先用于转换链路冒烟：

```bash
python fast_neural_style/script/model2tf_lite.py \
  --model checkpoints/model.model \
  --width 0.25 \
  --size 256 \
  --calib fast_neural_style/images/calib \
  --in-dtype int8 \
  --out-dtype int8 \
  --int8-tflite build/style_int8.tflite \
  --content fast_neural_style/images/content-images/amber.jpg
```

该脚本不能代替 TinyML 友好网络改造；最终应使用修改后的模型和校准代码。

### 7.3 全整数量化要求

转换器应满足：

```python
converter.optimizations = [tf.lite.Optimize.DEFAULT]
converter.representative_dataset = representative_dataset
converter.target_spec.supported_ops = [
    tf.lite.OpsSet.TFLITE_BUILTINS_INT8
]
converter.inference_input_type = tf.int8
converter.inference_output_type = tf.int8
```

校准集建议使用 200～1000 张真实摄像头风格的 RGB 图片，覆盖亮、暗、肤色、纹理和运动场景。

### 7.4 TFLite 模型检查

PC 端必须检查输入、输出、量化参数和算子：

```python
interpreter = tf.lite.Interpreter(model_path="style_int8.tflite")
interpreter.allocate_tensors()

print(interpreter.get_input_details())
print(interpreter.get_output_details())
print(interpreter._get_ops_details())
```

验收要求：

- 输入和输出均为 `int8`；
- Conv 权重为 `int8`；
- bias 为 `int32`；
- 没有 float32/hybrid 推理路径；
- 输入尺寸是静态的；
- 所有算子都能在板端 TFLite Micro Resolver 注册；
- INT8 输出与 FP32 输出的画质差异在可接受范围内。

量化换算必须读取张量自身的参数：

```text
q = round(real / scale) + zero_point
real = (q - zero_point) * scale
```

不要在部署代码中无条件写死 `x - 128`。

## 8. TinyML Generator 流程

### 8.1 第一次运行

先使用官方 Ti60F225 TinyML Hello World 工程做静态输入推理，不要一开始连接摄像头。

1. 启动 Efinity 环境。
2. 运行 `tinyml/tools/tinyml_generator/tinyml_generator.py`。
3. 打开全整数量化 `style_int8.tflite`。
4. 选择 `SINGLE CORE`、`CPU ID=0`。
5. Ti60 使用 `AXI_DW=128` 作为初始值。
6. 初始启用 `CONV_DEPTHW`、`ADD`、`LEAKY_RELU`。
7. 只有模型实际包含相应算子时才启用 `MUL`、`MIN_MAX`、`RESHAPE`。
8. 记录资源估算，再降低并行度直到有足够的 SoC/视频资源余量。
9. 点击 Generate。

Generator 输出目录通常包含：

```text
output/<model_name>_core0/
  tinyml_core0_define.v
  <model_name>_model_data.h
  <model_name>_model_data.cc
```

### 8.2 文件放置

```text
source/tinyml/tinyml_core0_define.v
embedded_sw/SapphireSoc/software/standalone/<application>/src/model/<model_name>_model_data.h
embedded_sw/SapphireSoc/software/standalone/<application>/src/model/<model_name>_model_data.cc
```

软件中使用：

```cpp
model = tflite::GetModel(<model_name>_model_data);
```

根据模型实际算子，在 `micro_mutable_op_resolver` 中注册 `Conv2D`、`Add`、`LeakyRelu`、`Pad`、`ResizeNearestNeighbor` 等所需算子。

### 8.3 加速器打开顺序

必须按以下顺序排查：

1. 所有 TinyML 加速器关闭，确认纯 TFLite Micro 软件推理正确。
2. 只打开 Conv/DepthwiseConv。
3. 打开 Add。
4. 打开 LeakyReLU。
5. 必要时打开 Mul/MinMax/Reshape。
6. 每一步都比较输出图、UART 日志和耗时。

官方软件也支持通过 `accel_settings.cc` 覆盖硬件设置；调试阶段可以将所有 `*_en` 置零，并设置 `override_flag=1`。

## 9. 摄像头和显示集成

官方 TinyML Vision 示例主要使用 Raspberry Pi 摄像头；本板使用 SC431HAI，不能直接复制其摄像头模块。

应复用当前 Iris 工程中的：

- CSI-2 RX；
- SC431HAI I2C 初始化；
- RAW 到 RGB/Debayer；
- DDR3 帧缓存；
- HDMI/DSI 显示链路。

推荐集成顺序：

```text
静态输入数组
  -> DDR 中的一帧
  -> 摄像头单帧
  -> 连续摄像头帧
  -> HDMI/DSI 输出
```

第一版建议将模型输入限制在 `256×256` 或 `320×240`，再将风格化结果放大到显示分辨率。当前四分之一通道模型在 `640×480` 上仍有较高 MAC 数，不应先承诺 `640×480@30fps`。

## 10. 里程碑与验收门槛

### M0：环境和仓库确认

- [ ] 固定 `examples` 的 `Iris` 分支 commit。
- [ ] 固定 Efinix TinyML tag 和 Efinity 版本。
- [ ] 记录 Python、PyTorch、TensorFlow、onnx2tf 版本。
- [ ] 确认 SC431HAI、DDR3、HDMI 工程可以单独运行。

### M1：模型训练

- [ ] TinyML 友好网络可以训练。
- [ ] checkpoint 可以严格加载。
- [ ] FP32 PC 推理结果正确。
- [ ] 参数量、输入尺寸和输出范围已记录。

### M2：转换和量化

- [ ] ONNX 与 PyTorch 输出误差可接受。
- [ ] float TFLite 与 ONNX 输出一致。
- [ ] INT8 TFLite 的输入/输出为 `int8`。
- [ ] 无 float/hybrid 算子。
- [ ] PC 上 INT8 与 FP32 画质可接受。

### M3：TinyML 软件推理

- [ ] Generator 能打开模型并生成文件。
- [ ] `.cc/.h` 已加入 Sapphire 软件工程。
- [ ] 纯软件 TFLite Micro 推理成功。
- [ ] Tensor arena 和 Application Region Size 足够。

### M4：硬件加速

- [ ] Conv 加速后输出正确。
- [ ] Add/LeakyReLU 逐步打开后输出仍正确。
- [ ] Efinity 编译通过。
- [ ] 资源、时序、DDR 带宽满足目标。
- [ ] UART profiler 已记录各层耗时。

### M5：视频系统

- [ ] 摄像头单帧可正确送入模型。
- [ ] 连续帧无 DMA/DDR 溢出。
- [ ] HDMI/DSI 输出颜色、尺寸和帧率正确。
- [ ] 记录端到端延迟、FPS、资源占用和功耗。

## 11. 主要风险和应对

| 风险 | 现象 | 应对 |
|---|---|---|
| `InstanceNorm` 未消除 | 生成 `MEAN/RSQRT` 链，硬件不加速 | 改 BN，训练后 BN folding |
| `ReflectionPad` 保留 | 出现 `PAD/MIRROR_PAD` | 改普通 Conv padding，或接受软件执行 |
| 上采样拖慢 | `RESIZE_NEAREST` 占用 RISC-V 时间 | 先软件执行，后续做预处理硬件 |
| 量化画质下降 | 输出色彩/边缘明显失真 | 增大校准集，改用 QAT，降低通道缩放幅度 |
| Generator 资源超限 | RAM/DSP/LE 不足 | 降低并行度、关闭 cache、使用 Lite、降低输入尺寸 |
| Tensor arena 不足 | `Allocate Tensor Failed` | 调大 arena，检查 DDR/Application Region Size |
| Efinity 时序失败 | P&R timing error | 降低并行度，调整 seed/optimization/placer effort |
| 摄像头链路问题 | 花屏、帧丢失、颜色错误 | 先独立验证 CSI/Debayer/DDR/HDMI，再接模型 |

## 12. 推荐的第一周执行顺序

1. 固定 `examples/Iris` 和 `tinyml` 的版本。
2. 用现有 `.model` 跑通一次 ONNX/float TFLite/INT8 TFLite 转换。
3. 写出 `TransformerNetTinyML`：普通 padding、BN、LeakyReLU。
4. 用小数据集重训 1 个 epoch，检查前向和导出。
5. 使用 20～50 张校准图生成第一个全 INT8 `.tflite`。
6. 用 TFLite Analyzer 列出全部算子和量化参数。
7. 用 Generator 打开模型，记录 Ti60F225 资源估算。
8. 复制官方 Ti60F225 TinyML Hello World 工程，先做静态图片纯软件推理。
9. 逐步启用 Conv、Add、LeakyReLU 硬件加速。
10. 最后再把模型接入 SC431HAI 摄像头和 HDMI 显示链路。

## 13. 参考资料

- [Efinix TinyML 主仓库](https://github.com/Efinix-Inc/tinyml)
- [TinyML Model Conversion](https://github.com/Efinix-Inc/tinyml/blob/main/docs/model_conversion.md)
- [TinyML FAQ](https://github.com/Efinix-Inc/tinyml/blob/main/docs/faq.md)
- [TinyML Generator](https://github.com/Efinix-Inc/tinyml/blob/main/tools/tinyml_generator/README.md)
- [TinyML Model Zoo](https://github.com/Efinix-Inc/tinyml/blob/main/model_zoo/README.md)
- [examples Iris 分支](https://github.com/FinResect/examples/tree/Iris/fast_neural_style)
- [Ti60F225 本地板卡用户手册](./Ti60F225_DemoBoard_v4_用户手册.md)
- [本地风格迁移模型核对](./风格迁移_模型核对与FPGA方案.md)
