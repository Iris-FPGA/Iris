# TinyML 移植进度与待办

更新时间：2026-10-05。

目标：将 one_last_kiss INT8 风格迁移模型接入 Iris 的 Ti60F225I3 摄像头/DDR3/HDMI
系统，最终由 RISC-V 调度，FPGA 执行模型的逐元素和卷积计算。

当前状态是**模型准备完成，静态输入固件骨架已落地，硬件集成尚未实施**。
没有生成可运行的目标 ELF，没有为此次移植生成 bitstream，没有烧板或验证帧率。
现有视频顶层和 Efinity 工程清单未修改。

## 生成文件来源

后续统一使用官方 Generator 的输出：

```text
/home/fr/Program/FPGA/tinyml/tools/tinyml_generator/output/one_last_kiss_0_int8_core0/
  tinyml_core0_define.v
  one_last_kiss_0_int8_model_data.h
  one_last_kiss_0_int8_model_data.cc
```

Iris 已有对应副本，调查时与上述文件一致：

- `iris_ws/src/cnn/tinyml_core0_define.v`
- `iris_ws/RISC-V/one_last_kiss_0_int8_model_data.h`
- `iris_ws/RISC-V/one_last_kiss_0_int8_model_data.cc`

不使用之前自写生成脚本产生的 `tinyml/one_last_kiss_0_generated` 作为集成来源。
模型为 125,336 字节，INT8 NHWC `[1,128,128,3]` 输入输出，含 16 个 Conv2D、5 个 Add、
2 个 ResizeNearestNeighbor。模型报告位于 `one_last_kiss_style/`。
模型已通过的软件检查不代表 TinyML 板端数值一致性已验证。

## 已落地内容

| 内容 | 路径/状态 |
|---|---|
| 现有视频系统 | `iris_ws/src/top.v`；已有摄像头、DDR3 帧缓存和 HDMI |
| 官方模型及配置副本 | 上述 `src/cnn` 与 `RISC-V` 目录；尚未接入运行硬件 |
| 静态模型固件骨架 | `firmware/tinyml_style/` |
| 固件构建入口 | `.script/build-tinyml-firmware` |
| 固件详细接口说明 | `firmware/tinyml_style/README.md` |

固件骨架复用外部 TinyML 仓库的 TFLite Micro、平台驱动及 `tinyml_lib.a`，固定参考版本
为 `96886fa0c73e25e6218db7d0863f84677cf65138`，没有批量复制第三方源码。
已经包含模型注册、确定性静态输入、加速器配置探测、逐层 profiler、arena 用量及输出校验和。
链接地址必须显式提供，不默认占用现有视频内存。

目前的固件**仍使用软件最近邻上采样**，官方 Conv/Add 内核也可能回退到软件。
因此 `STRICT_DISPATCH=1` 刻意拒绝构建；后续不能仅移除检查就宣称 CPU 只负责调度。

已完成的验证范围：host 模型格式/算子约定检查、固件入口的 host 语法检查、构建脚本语法及
严格模式/缺失依赖报错检查。host 语法检查不是 RISC-V 目标编译；输出校验和尚无黄金参考值。

## 待办顺序

### 1. 工具链与 Sapphire SoC

- [ ] 配置实际 Efinity 路径。调查时可用安装为 `/home/fr/efinity/2026.1`，
  `path/efinity_home` 仍指向不存在的 `/home/noir/Applications/efinity/2026.1`。
- [ ] 安装或指定 Efinity 配套 RISC-V GNU 工具链；调查时未找到可用的目标编译器。
- [ ] 在 Iris 中创建并生成单核 Sapphire SoC IP、wrapper、初始化 ROM 和对应 BSP。
- [ ] 复核 IP 版本：参考工程配置为 efx_soc 3.4.0，本机安装为 3.4.1，不能直接假设完全一致。
- [ ] 配置 RV32、与官方库匹配的 ISA/软浮点 ABI、自定义指令、128-bit 外部内存接口、
  UART、CLINT、PLIC 和调试接口。不要沿用其他工程的 BSP 代替 Iris 的生成结果。
- [ ] 明确启动方式、复位入口与 DDR 程序加载方式。首版建议通过调试器加载静态测试固件，
  flash 启动与 bootloader 后续单独验证。

验收：生成物和 BSP 完整、版本一致，最小串口程序能交叉编译；上板后能从预定存储区执行。
当前尚未创建 `iris_ws/ip/SapphireSoc` 或 IP 生成脚本。

### 2. 官方 TinyML RTL 接入

- [ ] 选定并记录与固件一致的官方 RTL 来源，接入 `tinyml_top`、加速器实现及依赖定义。
- [ ] 使用官方 output 的 Core 0 配置：AXI128、Standard Conv 4/2、Standard Add、Cache512。
- [ ] 处理版本差异：Generator 输出 `TML_C0_RESHAPE_MODE`，已检查的参考 RTL 使用
  `TML_C0_RS_MODE`。先确认最终源码要求，再在集成适配层映射，保留官方生成原件。
- [ ] 接通 Sapphire 自定义指令 cmd/rsp、背压、完成中断、时钟和复位。
- [ ] 加速器及 CPU 内存访问必须等 DDR 校准完成后释放；按需要同步跨域信号。
- [ ] 更新 Efinity 源文件清单及 SystemVerilog 设置，保留 IP 的初始化文件与许可头。

验收：RTL 可在 Efinity 中解析/展开，加速器能力查询能读回与配置一致的参数。
开源仿真器无法代替 Efinity 验证加密 IP。

### 3. DDR 共享与地址规划

现有 DDR 只有视频帧缓存主设备，`axi_atype_bridge` 不是多主 AXI 仲裁器。
拟采用以下连接，具体接口必须结合生成后的 Sapphire RTL 确认：

```text
视频帧缓存 -----------+
Sapphire CPU --------+--> 多主 AXI 仲裁 --> DDR 共享地址适配 --> 现有 DDR3
TinyML 加速器 -------+
硬件上采样（后续）---+
```

- [ ] 实现或接入已验证的多主仲裁，保留 CPU ID、burst、size、strobe 和错误响应。
- [ ] 地址被背压时保持选择与载荷稳定；写入地址、整个 W burst、B 响应必须属于同一主设备。
- [ ] 为读响应正确保存归属，避免其他主设备接收数据；设计公平性和显示读取延迟上界。
- [ ] 不直接照搬参考工程中省略部分 AXI 属性的互连，逐项确认其假设是否适用。
- [ ] 划分视频区、程序/模型区、tensor arena、栈/堆和输入输出缓冲，加入地址范围检查。
- [ ] 确定 CPU cache 与 TinyML cache 的 clean/invalidate、fence 和缓冲区所有权规则。
- [ ] 补充仿真：并发主设备、读写 burst、随机背压、响应 ID、错误响应、复位和越界访问。

现有三帧视频缓冲保守覆盖 `[0x00000000,0x005F4000)`；DDR 配置几何对应 256 MiB。
建议先保留前 8 MiB 给视频，推理程序从 `0x00800000` 或更高地址规划，边界不超过
`0x10000000`。这是待落实方案，不是已经生效的地址图。
参考 SoC 从 `0x00001000` 加载程序会与视频冲突；不能直接截断高位地址造成别名。
固件 README 中的地址示例也不是已建立的内存映射。

验收：共享内存仿真通过、CPU/加速器看到同一物理数据、视频无覆盖或持续欠载。
本轮未生成仲裁模块、测试平台或顶层接线。

### 4. 固件目标构建与静态推理

- [ ] 用实际生成的 BSP 填齐 `STANDALONE`、`BSP_PATH`、`RISCV_BIN`。
- [ ] 按最终地址规划指定 `DDR_BASE` 和 `DDR_BYTES`，验证 linker map 与硬件解码一致。
- [ ] 目标编译、链接并核对启动代码/系统调用。当前没有可运行 ELF。
- [ ] 验证 UART、计时器、TinyML 完成中断与加速器配置查询。
- [ ] 在板端运行静态输入，确认 `AllocateTensors()` 实际 arena 用量。
- [ ] 为同一输入生成 host TFLite 整数参考输出，逐元素比较板端输出；校验和只能辅助定位。
- [ ] 分别验证纯软件参考与硬件 Conv/Add 路径，记录逐层耗时及回退原因。

固件默认预留 2 MiB arena、2 MiB heap、16 KiB stack，属于初始预算，尚未测得实际需求。
静态输入使用梯度/棋盘测试图，不涉及摄像头，不代表已完成画面风格化演示。

### 5. 硬件最近邻上采样与严格调度模式

- [ ] 确认上采样控制接口和自定义指令编码，再同时实现 RTL 与驱动。
- [ ] 实现 INT8 NHWC、batch1、2 倍像素复制，支持本模型的 32 和 16 通道。
- [ ] 正确处理地址、对齐、写响应、错误、超时及 abort；完成标志必须晚于所有输出写入完成。
- [ ] 实现 TFLM Resize 注册/调用适配，量化参数相同则按位复制，不进行额外重定标。
- [ ] 禁止 Conv/Add/Resize 的隐式软件回退，不支持配置应返回明确错误。
- [ ] 加入黄金数据、背压、越界、超时和复位测试，再开放 `STRICT_DISPATCH=1`。

两层形状为 `[1,32,32,32] -> [1,64,64,32]` 和
`[1,64,64,16] -> [1,128,128,16]`，最近邻 align_corners/half_pixel_centers 均为 false。
最大单张中间特征图 256 KiB，不等于峰值 arena。

固件 README 提出了 function ID `0x200..0x206` 接口，但**只是提案**，尚未写 RTL，也未发出
这些指令。需确认 funct7/funct3 映射、物理地址与 cache 规则后才能采用。
临时软件 Resize 仅用于功能对照，不能作为“RISC-V 只调度”的最终验收。

### 6. 摄像头输入与显示输出

- [ ] 从去 Bayer 后的 RGB 数据取图；现有 DDR 视频帧为 RAW8 Bayer，不能直接当 RGB 输入。
- [ ] 明确与训练一致的裁剪、缩放、通道顺序和输入量化，逐像素处理放入硬件路径。
- [ ] 增加推理输入快照/缓冲所有权；现有三缓冲保护显示读取，不自动保护推理读取。
- [ ] 输出按模型实际 scale/zero point 转为显示像素并截断，使用独立输出缓冲及换帧握手。
- [ ] 推理帧率低于显示帧率时重复显示已完成结果，不能让 HDMI 等待推理完成。

验收：固定图与摄像头输入一致、无撕裂/覆盖，视频在推理和外存争用下保持稳定。

### 7. 整机资源、时序与性能

- [ ] 用实际 Efinity 版本完成完整工程 map/interface/pnr，检查资源和时序报告。
- [ ] 测量逐层推理时间、DDR 带宽、输入输出处理耗时及整帧延迟。
- [ ] 根据测量调整并行度/缓存，不能通过静默 CPU 回退来规避资源不足。
- [ ] 记录板端数值对比、工具版本、模型哈希、硬件配置和可复现构建命令。

此前核心估算约 16,809 LUT、11,736 FF、3,461 ADD、57 M10K、24 DSP，
不含 SoC、视频、互连及上采样。不能据此保证 Ti60 整机放得下，也不能直接将 LUT/FF/ADD
相加作为 XLR。旧视频工程的时序记录不能证明新增推理后的时序。

## 下一次继续的入口

从 Iris 根目录查看与检查现有固件骨架：

```bash
.script/build-tinyml-firmware --help
.script/build-tinyml-firmware check-model
```

`check-model` 会在固件的 build 目录产生 host 检查产物，但不访问板卡、不运行训练。
先完成工具链、Sapphire 生成和地址规划，再进入硬件连接和目标构建。
不要先将静态推理骨架标为可上板版本，也不要将现有视频构建成功视为 TinyML 集成成功。
