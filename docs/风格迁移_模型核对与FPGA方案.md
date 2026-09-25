# 风格迁移模型核对与 FPGA 实现方案

> 配套文档：《赛题一_实时绘画_任务分级与硬件实现分析.md》（任务分级/资源预算）、
> 《赛题一_实时绘画_实现方案与路线.md》（模块划分/里程碑）。
>
> 本文是对仓库根目录 `one_last_kiss_style.model` 的**实测核对**，并据此给出
> **放弃 TFLite / 官方 TinyML 路线、改走自研 INT8 行流式卷积加速器**的完整方案。
>
> 核对环境：分支 `dev/fastnst`，conda env `yolo`（torch 2.5.1），2026-09-26。
> 姊妹文档 `examples/fast_neural_style/部署易灵思Ti60.md`（TFLite 路线）**已废弃**，见第二节。

---

## 目录

- [一、模型核对结论（实测）](#一模型核对结论实测)
- [二、为什么放弃 TFLite / 官方 TinyML 路线](#二为什么放弃-tflite--官方-tinyml-路线)
- [三、方案：自研 INT8 行流式卷积加速器](#三方案自研-int8-行流式卷积加速器)
- [四、预算核对](#四预算核对)
- [五、分阶段计划 P0~P4](#五分阶段计划-p0p4)
- [六、未决项与风险](#六未决项与风险)

---

## 一、模型核对结论（实测）

### 1.1 文件性质与加载

| 项 | 实测结果 |
|---|---|
| 路径 | `Iris/one_last_kiss_style.model`（459,733 B，**未纳入 git**） |
| 格式 | **PyTorch `state_dict` zip**（`torch.save` 的 zipfile 形式），内部 `data.pkl` + `data/0..61` |
| checkpoint 标签 | `epoch_2_2026-09-20_01-31-21_100000.0_10000000000.0` → epoch 2，content_weight=1e5，style_weight=1e10 |
| 条目数 | 62 个 tensor（16 组 conv w/b + 15 组 IN γ/β） |
| 来源代码 | `examples/fast_neural_style/neural_style/transformer_net.py`（`--width 0.25`） |
| 加载验证 | `TransformerNet(width=0.25).load_state_dict(sd, strict=True)` **通过**，`1×3×256×256` 前向正常 |

> 注意：**它不是 `.keras`、不是 ONNX、更不是 `.tflite`**，是 PyTorch 权重包。
> 上板前必须先做自己的导出与量化（见第三节）。

### 1.2 网络结构（width=0.25 → 通道 8/16/32）

| # | 层 | 参数 shape | 输出尺寸（输入 256×256） | 备注 |
|---|---|---|---|---|
| 1 | `conv1` ReflectPad(4)+Conv 9×9 s1 + IN + ReLU | (8,3,9,9) | 256×256×8 | 全分辨率 |
| 2 | `conv2` ReflectPad(1)+Conv 3×3 **s2** + IN + ReLU | (16,8,3,3) | 128×128×16 | ↓2 |
| 3 | `conv3` ReflectPad(1)+Conv 3×3 **s2** + IN + ReLU | (32,16,3,3) | 64×64×32 | ↓2 |
| 4~13 | `res1..res5` ×(Conv3×3+IN+ReLU, Conv3×3+IN, **+residual**) | (32,32,3,3) ×10 | 64×64×32 | 5 个残差块 |
| 14 | `deconv1` **nearest×2** + ReflectPad + Conv3×3 + IN + ReLU | (16,32,3,3) | 128×128×16 | ↑2（不是 ConvTranspose） |
| 15 | `deconv2` **nearest×2** + ReflectPad + Conv3×3 + IN + ReLU | (8,16,3,3) | 256×256×8 | ↑2 |
| 16 | `deconv3` ReflectPad(4)+Conv 9×9 s1 | (3,8,9,9) | 256×256×3 | 无 IN / 无 ReLU |

**算子清单（共 16 卷积 / 15 InstanceNorm / 10 ReLU / 5 残差加 / 2 最近邻上采样 / 反射填充 / 输出 clamp）**
—— 全部可在 RTL 中直接实现，**没有任何一个必须依赖 TFLite**。

`deconv*` 名字带 deconv，但 state_dict 中 shape 为 `(out,in,3,3)`，且 `transformer_net.py:99`
用的是 `F.interpolate(nearest, ×2)` + 普通卷积（`transformer_net.py:24-28, 94`），
**不是 `ConvTranspose2d`** —— 对硬件反而更友好（地址生成做 ×2 复制即可）。

### 1.3 参数量与体积

| 项 | 数值 |
|---|---|
| 总参数 | **108,771**（卷积 107,568 + IN 仿射 1,203） |
| FP32 权重 | **435,084 B ≈ 425 KB**（< 500 KB 规则 ✓，`赛题一…分析.md:73`） |
| INT8 权重 | **≈ 107 KB** + per-channel scale（16 层共 423 个）≈ 109 KB |
| vs 片上 RAM | 片上仅 **327 KB**（`赛题一…分析.md:117`）→ INT8 权重**可整网常驻片上**（见 4.3） |

### 1.4 数值域（决定硬件输入/输出接口）

| 项 | 结论 | 出处 |
|---|---|---|
| 输入 | **RGB 0~255**，**无** ImageNet 归一化 | `neural_style.py:43-46` `Lambda(x*255)` |
| 输出 | raw 输出无界（实测随机输入下 -92.7 ~ 310.2），保存前 **`clamp(0,255)`** | `utils.py:15` |
| 硬件含义 | 从 debayer 取 RGB888 直接喂网络即可；**输出级必须做 clamp 0~255**，否则显示溢出 |

### 1.5 算力（决定可行性的核心数字）

每输出像素 MAC 数（按各自分辨率折算到全分辨率基准）：

| 层 | MAC/像素 | 占比 |
|---|---:|---:|
| conv1 (9×9, 3→8) | 1,944 | 15.5% |
| conv2 (3×3, 8→16, ↓4 面积) | 288 | 2.3% |
| conv3 (3×3, 16→32, ↓16 面积) | 288 | 2.3% |
| res1..5（10 个 3×3 32→32, ↓16 面积） | 5,760 | **46.0%** |
| deconv1（↑2 后 3×3 32→16） | 1,152 | 9.2% |
| deconv2（↑2 后 3×3 16→8） | 1,152 | 9.2% |
| deconv3 (9×9, 8→3) | 1,944 | 15.5% |
| **合计** | **12,528 MAC/px** | 100% |

| 处理分辨率 | GMAC/帧 | @15 fps | @30 fps | 判定（峰值 64 / 有效 13~26 GMAC/s，`赛题一…分析.md:150-152`） |
|---|---:|---:|---:|---|
| 256×256 | 0.82 | 12.3 | 24.6 | 15fps ✓ 稳（占有效算力 47~95%） |
| **320×240** | **0.96** | **14.4** | 28.9 | 15fps ✓（需 ≥22% 峰值效率）；30fps 偏紧 |
| 640×480 | **3.85** | **57.8** | 115.6 | ✗ **15fps 就需 90% 峰值效率，不可行** |

> ⚠️ **修正既有文档**：《实现方案与路线.md:100》写"FNS 1/4 通道在 640×480 约 **0.5~1.5 GMAC/帧**
> ×15fps = 7.5~22.5 GMAC/s，可行"。**对本模型实测不成立**——本模型 640×480 是 **3.85 GMAC/帧**，
> 是该估算上限的 2.6 倍（差异来自 5 个残差块 + 首尾两个 9×9 大核，二者合计占 77% 计算量）。
> 结论必须改为：**网络按 ≤320×240 跑，输出再放大到 640×480 显示**（见 4.1 / 六之未决项）。

---

## 二、为什么放弃 TFLite / 官方 TinyML 路线

原路线见 `examples/fast_neural_style/部署易灵思Ti60.md`（PyTorch→ONNX→TFLite→TinyML Generator），
核对模型后判定**不可行**，理由三条：

1. **算子覆盖缺口（致命）**
   - `ReflectionPad2d` → ONNX `Pad(mode=reflect)` → TFLite `MIRROR_PAD`：TFLite Micro 有 kernel，
     但 **Efinix TinyML Accelerator 不一定加速**，会掉回 RISC-V 逐算子执行；
   - `InstanceNorm2d(affine, track_running_stats=False)` → TFLite **无原生算子**，必须分解成
     `MEAN/RSQRT/SUB/MUL/ADD` 链（`部署易灵思Ti60.md:39`），其中 `RSQRT`/`MEAN` 在加速器侧覆盖存疑；
   - nearest `×2` 上采样 → `RESIZE_NEAREST`，同样不在常见加速器算子集内。
   - **任何一个算子掉出加速器，整网性能就由最慢的一环决定**，而本网络 15 个 IN 全在关键路径上。

2. **性能不可达**：TFLite Micro 是解释执行 + 软核访存，即使全覆盖也比专用 RTL 卷积引擎慢
   1~2 个数量级。L4 硬指标是 **640×480 ≥15 fps**（`赛题一…分析.md:96`），
   本来就已经压在 160 DSP 的临界点上，没有余量给软核开销。

3. **附带收益：工具链大幅简化**
   - 完全**不需要** TensorFlow / ONNX / onnx2tf / TFLite Converter，原计划
     "Py3.14 无 TF、需另建 3.10/3.11 环境"（`部署易灵思Ti60.md:91-95`）的问题**直接消失**；
   - 现有 conda env `yolo`（torch 2.5.1 + numpy + cv2 + PIL）即可完成
     **权重导出 + INT8 定点仿真 + PSNR/SSIM 验证**，零新增依赖。
   - 原 `neural_style.py:156-160` 用的旧 API `torch.onnx._export` 也一并绕开，不再需要改它。

**结论：不再走 TFLite，直接在 FPGA 上自研 INT8 卷积加速器（对应任务分级的 M4）。**

---

## 三、方案：自研 INT8 行流式卷积加速器

### 3.1 总体数据通路

```
                        ┌─────────────────── Ti60F225 ───────────────────┐
SC431HAI ─CSI RX─► sensor_clipper ─► Debayer/AWB ─► [Resize → 处理分辨率]
                                                          │
                                        ┌─────────────────▼──────────────────┐
                                        │  M4 CNN 加速器（本方案，AXI4 master）│
                                        │  权重(片上) + 特征图(DDR ping-pong)  │
                                        └───────┬──────────────────┬─────────┘
                                          原图分支              风格化分支
                                                └────► [×N 放大] ◄┘
                                                        │
                                     对比视图/OSD/FPS ─► DVI TX ─► HDMI
        RISC-V Sapphire ──APB/IRQ──► 层描述符、启停、风格切换（L3/L5a）
```

- **插入点 A（先做，L2/L3 首选）**：DDR 离线通路。写帧 → 加速器按层读写 DDR → 显示读风格化缓冲。
  优点：单帧可离线比对，正好对应 L2 验收"单帧风格化结果正确（可先跑固定测试图/离线比对）"
  （`赛题一…分析.md:94`）；复用现有 `axi_atype_bridge` / `frame_buffer` 仲裁。
- **插入点 B（后期优化，L5b）**：debayer 之后行流式直连（`top.v:412` debayer → `top.v:439` afifo 之间），
  省一次 DDR 往返，对应 `赛题一…分析.md:80`"避免整帧宏流水、采用行流水线"。

### 3.2 引擎微架构：层串行 + 行流式

16 个卷积**共用一个引擎**，按层状态机顺序执行，每层流程：

```
DDR 读 K 行 ─► 行缓存(BRAM, 反射寻址) ─► 窗口滑动 ─► PE 阵列(权重驻留) ─► 累加
                                                            │
              DDR 写回 ◄─ clamp/requant ◄─ ReLU ◄─ InstanceNorm 后处理 ◄─┘
```

| 子模块 | 职责 | 资源 |
|---|---|---|
| `cnn_accel_top` | AXI4 master（读输入/权重、写输出）+ APB 寄存器 + IRQ | ~2~4K LE |
| `layer_desc` 表 | 每层描述符：K / stride / Cin / Cout / W / H / pad 模式 / 激活 / upsample / 残差地址 / 量化参数地址 | 寄存器或 BRAM |
| `line_buffer` | K 行 × Cin × W 字节 TDP RAM；**行首/列首地址做镜像即实现 `ReflectionPad2d`**（零额外算力） | 30~60 KB |
| `pe_array` | P 个 int8 MAC，权重驻留（weight-stationary），输入通道广播、输出通道并行 | P 个 DSP |
| `post_pipe` | int32 累加 → InstanceNorm 两遍法 → ReLU → requant → clamp | 1~3K LE + 少量 DSP/LUT |
| `sequencer` | 16 conv + 15 IN + 10 ReLU + 5 残差加 + 2 上采样的调度 | ~1K LE |

**PE 阵列数据流**：权重固定（每输出通道占一组权重 bank），一拍把同一组输入广播给全部 PE、
P 个输出通道同时累加；产出一组 P 个完整输出像素需 `Cin×K²` 拍，**期间每个 PE 每拍都在做 MAC**。
效率损失只来自行首行尾 halo、层切换与 DDR 停顿 —— 这是比文档 20~40% 假设更乐观的点，
但 P（并行度）必须由 P0 实测决定（见第五节）。

### 3.3 量化与定点设计（离线工具链的产出规格）

| 项 | 方案 |
|---|---|
| 权重 | **per-output-channel 对称 INT8**（16 层 423 个 scale） |
| 激活 | per-tensor **非对称 INT8/UINT8**（ReLU 后全非负，利用率高）；zp 折叠：预存 `Σw`，累加后一次减法 |
| 累加 | INT32（DSP 48-bit 累加器富余） |
| requant | `acc × M(Q31) >> shift + zp`，再 clamp |
| 输出级 | clamp 0~255 → UINT8 RGB（对齐 `utils.py:15`） |
| 中间缓冲 | DDR 中特征图统一 INT8，每个 IN 层的 INT32 统计量另行存储 |

### 3.4 InstanceNorm 处理（本方案与 TFLite 路线的分水岭）

IN **无法离线折叠**（`track_running_stats=False`，逐图逐通道统计），文档已预警
（`赛题一…分析.md:234`"Instance Norm 无法离线折叠，需运行时统计"；风险表 `:396`）。
本方案采用 **运行时两遍法**：

1. **第 1 遍（与卷积写回合并）**：写卷积 INT32 结果到 DDR 的同时，按通道累加 `Σa`、`Σa²`；
2. **第 2 遍**：读回 → `y = γ·(a−μ)·rsqrt(σ²+ε) + β`（`rsqrt` 用 LUT/Q 定点）→ ReLU → requant → 写回。

- 代价：每个 IN 层多一次读 + 一次写（全网 **+7.07 MB/帧** @320×240），带宽充裕（见 4.2）；
- 硬件代价：一个通道级累加器 + 一次定点乘法，**不改网络结构、不重训、画质与 PyTorch 一致**；
- 备选（未决项）：冻结统计量当 BN 折叠（最快但画质随内容漂移，需重校准/重训），仅在两遍法实测
  带宽或时序不达标时降级使用。

### 3.5 多风格与规格对齐

- **L5a 多风格**：每风格一套 INT8 权重（约 110 KB）放 DDR/片上多 bank，切换 = **换权重基址 + 重载描述符**，
  远小于 100 ms、不重配 FPGA（`赛题一…分析.md:97`）；
- **L5c 超轻量网络**：本模型 FP32 425 KB / INT8 107 KB，**已满足 <500 KB**，直接可作为 L5c 提交物，
  附 PSNR/SSIM 对比（工具链产出）；
- **L5b 720p@30**：**处理分辨率不升**，仅把输出最近邻/双线性放大到 1280×720，显示侧满足
  `1280×720@30`，而 CNN 算力需求只跟处理分辨率走（320×240@30 = 28.9 GMAC/s，需先测实际效率再定帧率）。

---

## 四、预算核对

### 4.1 算力

见 1.5 表。基线取 **320×240 / 15 fps = 14.4 GMAC/s**：
- 相对理论峰值 64 GMAC/s 需 **22%** 效率；
- 相对文档给出的有效区间 13~26 GMAC/s 落在**下沿**，可行但**必须在 P0 用 DSP 打包实测复核**。

### 4.2 DDR 带宽（320×240 处理，INT8）

| 项 | MB/帧 | @15 fps | 说明 |
|---|---:|---:|---|
| 卷积层读 | 4.68 | 70 MB/s | 输入 0.23 + 各层输出回读 |
| 卷积层写 | 3.76 | 56 MB/s | 16 层输出 |
| InstanceNorm 两遍法附加 | 7.07 | 106 MB/s | 15 个 IN 层各一次读+写 |
| **CNN 小计** | **15.5** | **233 MB/s** | |
| 相机写入（Bayer 1280×720@30） | — | 28 MB/s | 现有链路 |
| 显示读取（RGB888 1280×720，60~120 Hz） | — | 166~332 MB/s | 现有链路 |
| 风格化帧回写 + 放大（可选） | — | 0~124 MB/s | **若在显示读出路径上做放大，可省掉** |
| **合计（最坏）** | | **≈ 717 MB/s** | 占 1.6 GB/s 峰值 **45%** ✓（`赛题一…分析.md:148`） |

> 结论：**带宽不是瓶颈**，中间特征图**不必做层间融合**，v1 用最简单的"每层整图进出 DDR"即可；
> 层间融合/行直通留给 L5b 优化（对应 `赛题一…分析.md:72,398`）。

### 4.3 片上 BRAM（327 KB 总量，最紧的一项）

| 项 | 估算 | 说明 |
|---|---:|---|
| INT8 权重 + scale | ~110 KB | 整网常驻；**若放不下**，退化为 DDR 流式 + 双缓冲权重缓存（最大单层 32×32×9=9 KB，缓存 18 KB 即可，`赛题一…分析.md:244`） |
| 行缓存（K 行 × Cin × 宽） | 30~61 KB | 3×3@32ch×宽320 = 30 KB；9×9@8ch = 23 KB；宽 640 则翻倍到 61 KB → **又一个倾向 ≤320 宽的理由** |
| 现有 FIFO（DDR WR/RD 各 16 KB + CSI RX + debayer） | ~40 KB | `top.v:292-294` 等 |
| **合计** | **≈ 180~210 KB / 327 KB** | 余量约 35%，**须以 P0 重跑的资源报告为准** |

### 4.4 DSP / LE

- 需求：P 个 DSP（P = PE 数，P0 实测后定 32/64/…），文档估算 L2~L4 阶段
  LE `L1 + 10~25K (+SoC 10~15K)`、DSP `32~128`（`赛题一…分析.md:337-339`）；
- 风险：CSI RX IP + DDR3 控制器 + Sapphire SoC 先占大头，**CNN 要预留 DSP/BRAM**
  （`赛题一…分析.md:342`）→ 必须先拿到当前设计的真实占用。

---

## 五、分阶段计划 P0~P4

| 阶段 | 内容 | 交付物 | 验收标准 |
|---|---|---|---|
| **P0 基线与决策** | ① 重跑 `.script/build-iris` 拿**当前** MIPI+DDR 设计的 LUT/BRAM/DSP 真实占用（现有 `outflow/*.rpt` 是 **09-18 的 L0 彩条构建**，源码 09-24 已改，**已过期**）；② **DSP 打包微实验**：例化 160 个 int8 MAC 跑通，测 MAC/DSP 与 Fmax；③ 安装 RTL 仿真器（当前机器 **verilator/iverilog 均缺失**）；④ 冻结处理分辨率 | 资源报告 + 算力实测数字 + 分辨率决议 | 得出真实 GMAC/s，反推分辨率与并行度 P |
| **P1 离线工具链（纯 Python，不装 TF）** | `deploy/`：`export_weights.py`（state_dict→INT8 hex+scale 表）、`calibrate.py`（内容图校准激活范围）、`golden_ref.py`（NumPy 定点 **bit-exact** 参考：反射填充/步长2/IN 两遍法/上采样/残差/clamp）、`verify.py`（FP32 vs INT8 的 PSNR/SSIM）、**定点规格说明** | INT8 vs FP32 **PSNR ≥ 25~28 dB**、逐像素 golden 向量 |
| **P2 RTL 加速器** | `iris_ws/src/cnn/`：`cnn_accel_top` / `line_buffer` / `pe_array` / `post_pipe` / `sequencer` | 仿真输出与 `golden_ref` **逐像素 bit-exact** |
| **P3 集成（L2→L4）** | 插入点 A（DDR 通路）→ 单帧离线比对（L2）→ 上屏（L3）→ 对比视图 + FPS OSD（L4，复用 `osd_fps`/`fps_counter`） | 640×480 显示 **≥15 fps**，FPS 上屏 |
| **P4 加分项（L5）** | L5a 多风格换基址切换；L5b 720p@30 显示 + 行直通降访存；L5c 提交本模型 + PSNR/SSIM/延迟报告 | 逐项对照 `赛题一…分析.md:97-99` |

里程碑工作量粗估（在 `实现方案与路线.md:168` 的日程上叠加）：P0 ≈ 2 天，P1 ≈ 3 天，
P2 ≈ 1~2 周，P3 ≈ 1 周，P4 各项独立。

---

## 六、未决项与风险

### 6.1 待决策（阻塞 P2，需先定）

1. **处理分辨率**：320×240（推荐，14.4 GMAC/s@15fps，行缓存 30 KB）/ 256×256（与训练一致，最省，
   但非 4:3 需裁剪或非等比放大）/ 640×480（**算力不可行，除非砍残差块或换更轻网络并重训**）。
2. **InstanceNorm**：运行时两遍法（推荐，保真、带宽已验证够）/ 冻结统计折叠（最快但画质漂移）。
3. **权重存放**：片上常驻 110 KB（推荐，先看 P0 资源报告）/ DDR 流式 + 18 KB 双缓冲缓存。

### 6.2 风险表

| 风险 | 影响 | 缓解 |
|---|---|---|
| 片上 BRAM 不足（110 KB 权重 + 行缓存 vs 327 KB） | 权重无法常驻 | DDR 流式权重（`赛题一…分析.md:244`）；行缓存宽度随分辨率下降 |
| DSP int8 打包效率未知 | 算力结论不成立 | **P0 微实验先行**，拿到真实 MAC/DSP 与 Fmax 再定 P |
| 当前设计资源从未真实报告 | 预算全靠猜 | P0 重跑 `build-iris` |
| 640×480 全分辨率诉求与算力冲突 | L4 达不成 | 处理降分辨率 + 输出放大（显示仍是 640×480） |
| IN 两遍法访存被低估 | 带宽/CPU | 4.2 已含全额 7.07 MB/帧；仍超预算则层间融合或降级冻结统计 |
| int8 画质下降 | L5c 指标 | per-channel 权重量化已定；不达标再上 QAT 重训 |
| 无 RTL 仿真器 | P2 无法验证 | P0 安装 verilator/iverilog（系统改动，需确认） |

### 6.3 待办清单（下一轮动作）

- [ ] P0-1 重跑 `.script/build-iris`，记录 LUT/FF/BRAM/DSP 真实占用
- [ ] P0-2 DSP int8 打包微实验（MAC/DSP + Fmax）
- [ ] P0-3 安装 RTL 仿真器（verilator 或 iverilog）
- [ ] P0-4 决议：处理分辨率 / InstanceNorm 方案 / 权重存放
- [ ] P1 建 `deploy/` 工具链 + 定点规格说明
- [ ] 文档同步：`实现方案与路线.md:100` 的算力估算按 1.5 修正

---

## 参考

- 模型结构：`examples/fast_neural_style/neural_style/transformer_net.py`
- 训练/推理与数值域：`examples/fast_neural_style/neural_style/neural_style.py`、`utils.py`
- 已废弃的 TFLite 路线：`examples/fast_neural_style/部署易灵思Ti60.md`
- 任务分级与资源预算：`docs/赛题一_实时绘画_任务分级与硬件实现分析.md`
- 模块划分与里程碑：`docs/赛题一_实时绘画_实现方案与路线.md`
