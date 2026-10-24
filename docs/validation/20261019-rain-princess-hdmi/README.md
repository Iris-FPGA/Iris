# Rain Princess：完整 TinyML 摄像头与 HDMI 分屏

使用用户提供的完整 `rain-princess-cropped_style_int8.tflite`，没有蒸馏、重训或替换网络。模型 SHA256：`26852af8672516371f19b05e0dcd06ba6c533c13d9cc78fcf2b65b3f838729c5`。官方 TinyML 固定版本为 `96886fa0c73e25e6218db7d0863f84677cf65138`。

## 显示和数据通路

HDMI 为 1920×1080，左右各 960×1080。左侧直接显示实时摄像头；右侧保持最近一帧完整 AI 输出，在 VS 边界切换。用户已确认尺寸正常、左侧流畅、右侧 AI 仍卡顿。

完整 1920×1080 摄像头画面采样到模型原生 128×128 RGB INT8 输入，紧密 C3 DMA 送入官方 TinyML，执行全部 16 Conv、5 Add 和 2 Resize，再经 DDR、反量化和显示缩放输出。模型输入/输出尺寸仍为 128×128；960×1080 是显示尺寸。输出量化 scale=2.283437490463257、zero_point=-89。

CPU 负责解释器和调度，像素采集、打包、DMA、卷积、Add、Resize、反量化与显示在硬件完成。严格分派遇到硬件不支持会停止。三银行所有权阻止读写覆盖；只有完整成功的输出才可显示。

## 已验证的 4×2 / cache1024 基线

- 原 cache512 连续 Invoke 约 4.61 秒；cache 关闭约 7.37 秒。
- 官方 cache 深度改为 1024 后，连续 Invoke 约 0.6464 秒，实际输出约 1.43 FPS，帧间隔约 0.69～0.70 秒。此速率仍有明显运动停顿，未达到流畅视频。
- FPGA 资源：60,670 / 60,800 XLR，255 / 256 RAM，45 / 160 DSP；时序 setup +0.024 ns、hold +0.026 ns。
- 5 次连续帧提交成功，采集、显示、总线错误计数均为零。
- 从已显示银行读回的 49,152 字节 AI 输出与同一摄像头输入的 TensorFlow Lite BUILTIN_REF 逐字节相同，最大误差 0。
- `CAM`/`HDMI` 的 60 FPS 表示摄像头/显示刷新；`AI 01.43 FPS` 表示完整神经网络的新输出速率。

证据：`rectangle-cache1024-debug.json`、`rectangle-camera-parity.json`、`rectangle-model-identity.json`、`rectangle-program-sram.log`。对应位流为 `firmware/tinyml_style/build/rain_princess_rect_cache1024/iris_ws/outflow/iris_ws.bit`。

## 完整模型 8×2 / Add LITE / cache1024 基线

- 官方卷积采用 8 路输入、2 路输出并行；Add 采用官方 LITE 硬件，模型字节和全部 23 个节点不变。
- 捕获突发暂存采用 96 位 RAM + 32 位寄存器，保留四拍传输，节约逻辑以适配 Ti60。
- 连续 12 帧 Invoke 中位数 0.36362673 秒，实际新帧间隔约 0.416 秒，约 **2.40 FPS**。
- FPGA 使用 60,669 / 60,800 XLR、255 / 256 RAM、53 / 160 DSP；setup +0.012 ns、hold +0.026 ns。
- `rectangle-8x2-hybrid-debug.json` 与 `8x2-hybrid-camera-parity.json` 记录连续运行及 49,152 字节完整输出逐字节相等。

曾误加载远程 `micro4_d2` 学生模型对照位流，导致显示回到旧版黑白路径。用户明确要求仅借鉴旧后端技术后，已恢复此完整 Rain Princess 彩色版本。未写 Flash。恢复记录为 `restored-complete-model-program-sram.log`、`restored-complete-model-debug.json`、`restored-complete-model-reference-parity.json` 和 `restored-model-identity.json`。恢复后连续 5 帧完成，采集/显示错误为零，输出仍与原模型参考完全相等。用户已确认“已恢复彩色，但仍卡顿”。

恢复彩色时的位流为 `firmware/tinyml_style/build/rain_princess_rect_8x2_hybrid/iris_ws/outflow/iris_ws.bit`，固件为 `firmware/tinyml_style/build/rain_princess_live/tinyml_style.elf`。之后使用下述预采集和突发 DMA 优化。

### 三银行预采集基线，约 2.60 FPS

`LIVE_PIPELINE=1` 使用第三个空闲银行，在当前完整网络推理时采集下一帧。显示、推理和采集银行均保留独立所有权，提交前重新选择当前输出银行，仍只在 VS 后发布成功的完整结果。预采集会让输入排队等待当前 Invoke；本次验证吞吐和数值正确性，未声称降低端到端延迟。

使用同一 `8x2_hybrid` 位流和 `firmware/tinyml_style/build/rain_princess_pipeline/tinyml_style.elf`，连续 20 帧成功，实际提交间隔约 0.384 秒（中位速率 **2.602 FPS**），Invoke 中位数 0.36319802 秒，错误计数为零。最后提交 20 帧、采集 21 帧，证明下一银行已完成预取。读取当前显示银行的成对输入输出，49,152 字节仍与 BUILTIN_REF 完全相等。运行结束后 CPU 恢复运行。

证据：`pipeline-hybrid-debug.json`、`pipeline-hybrid-reference-parity.json`、`pipeline-hybrid-program-sram.log`、`pipeline-leases-rtl.log`。此调度仍远低于 30 FPS。

## 当前板上：原模型专用突发 DMA，约 2.72 FPS

2026-10-20 的 `rain_princess_rect_8x2_burst_rgb` 保留相同完整模型、8×2 卷积、Add LITE、cache1024 和三银行预采集，仅优化输入/输出张量搬运与 Resize 后端。使用两拍寄存器缓存，将同一组输入复用于 Resize 的上下两行；RGB copy 支持 C3，两次原模型 Resize 使用 C32、C16。后端不生成原模型未使用的 C4/C8 分支，不改变网络节点或权重。

- 连续 **60 个**新输出完成；Invoke 中位数 **354.54544 ms**，提交间隔中位数 **367.94349 ms**，约 **2.7178 FPS**。最后显示 60 帧、采集 61 帧，underflow/readerr/rejects 均为零。
- 后续只读串口复查时已显示 **699 帧**；连续采样的 667～699 帧序号完整，累积错误计数仍全部为零，未出现 STOP。证据为 `burst-rgb-soak-uart.log`、`burst-rgb-soak.json`。
- 已显示银行的 49,152 字节输出与同一输入的 BUILTIN_REF **逐字节相等**，误差为 0。模型 SHA256 与上述原模型一致。
- 资源：**60,328 / 60,800 XLR**、**255 / 256 RAM**、**53 / 160 DSP**。最终最小 setup **+0.016 ns**、hold **+0.026 ns**。
- 首帧分项计时：卷积合计 **328.39248 ms**，Add 合计 **22.55572 ms**，Resize 合计 **2.95772 ms**。这些是算子计时，不含完整显示间隔；卷积仍占约 93% 推理耗时。
- 相比预采集基线约 2.60 FPS，本次吞吐提升约 4.4%，**没有达到 30 FPS**。原模型和显示尺寸不变，仅写 SRAM，测试后 CPU 继续运行。

当前位流：`firmware/tinyml_style/build/rain_princess_rect_8x2_burst_rgb/iris_ws/outflow/iris_ws.bit`，SHA256 `6ee41aeab508f75deff0e38da5e5edfd48798328c4ec71e508cb35ccd82e05b8`；固件：`firmware/tinyml_style/build/rain_princess_pipeline/tinyml_style.elf`。证据为 `burst-rgb-live-debug.json`、`burst-rgb-reference-parity.json`、`burst-rgb-performance.json` 和 `burst-rgb-program-sram.log`。硬件变化后的稳定性证据独立记录，不沿用旧位流的 2,733 帧运行记录。

## 30 FPS 的后端约束

验收要求每秒 30 帧新的完整 AI 输出，单帧预算 33.33 ms。HDMI 60 Hz、重复帧或插值不能计入该速率。原模型每帧 148,635,648 MAC，需要至少 4.459 GMAC/s；100 MHz 下，仅计算就要求平均 44.59 MAC/周期。

当前 16 路 MAC 的理论计算上限也不足 30 FPS。官方 16×4 / Add LITE / cache1024 候选实际综合占用 75,945 XLR、281 RAM，均超过 Ti60 的 60,800 XLR / 256 RAM，因此未生成可用位流、未下载；证据在 `16x4-capacity-build.log` 及独立工程报告中。当前配置的 5 个 Add 共约 23 ms，2 个 Resize 共约 11.3 ms，卷积仍是主要耗时。单纯提高并行参数不能解决容量与搬运开销。

后续只保留新模型，借鉴旧实现的行缓存、片上特征复用、成组 DMA 和计算流水线。`complete-model-backend-budget.json` 从原 FlatBuffer 提取逐层算量：8×8 并行的理想卷积计算需 25.07 ms，尚未计入其他节点和任何搬运、调度开销；这仅是计算下界，不能当作容量或帧率证明。

`BURST_DMA` 每个 AXI 突发不跨 4 KiB，保留 C3 数据、诊断流、最终 B 确认和异常排空规则。容量实验依次为四拍首版 62,575 XLR、合并四拍版 61,448 XLR、两拍通用版 60,890 XLR、压缩配置通用版 60,851 XLR，均超过 Ti60 容量，均未下载。最后按原模型实际通道裁减的 RGB 专用版降到 60,328 XLR，已通过上述板上验证。

内部 DDR 地址计数器为 28 位，上游仍用完整 33 位范围检查拒绝 256 MiB 越界、32 位回绕和输入输出重叠。配置检查完整 32 位维度和通道值后才接受请求，非法高位不会因寄存器裁减而被截断为合法值。最终参数回归 `burst-dma-final-parameter-rtl.log` 覆盖默认、通用突发、原模型专用三组，检查真实 Resize 尺寸、逐字节输出、跨页 C32/C3、随机总线停顿、诊断流、R/B 错误和 abort 排空。该功能在主工程默认关闭，用 `prepare-tinyml-project.py --live-rgb --burst-dma` 显式启用。

即使完全消除 DMA 和 Add 耗时，现有 8×2 卷积的理想计算下界仍为 97.32 ms，达不到每帧 33.33 ms。要继续逼近 30 FPS，必须改造卷积计算结构、片上数据复用以及 Add 的量化流水线；本次传输优化不能作为这一目标已可实现的证据。

`.script/run-tinyml-live` 现在在连接板子前检查 RGB 工程参数，以及 ELF 内完整模型的 SHA256 与工程是否相同；可用 `--expected-model` 固定用户提供的模型，`--check-only` 只核验文件，避免再次混用旧学生模型位流与新模型固件。

## 复现

在项目根目录执行，工具链路径按本机设置：

```sh
.script/build-tinyml-firmware MODEL_PROFILE=rain_princess LIVE_DEMO=1 LIVE_PIPELINE=1 \
  OBJDIR=build/rain_princess_pipeline \
  STANDALONE="$PWD/iris_ws/embedded_sw/SapphireSoc/software/standalone" \
  BSP_PATH="$PWD/iris_ws/embedded_sw/SapphireSoc/bsp/efinix/EfxSapphireSoc" \
  RISCV_BIN=/mnt/mydata/Iris/dev/toolchains/xpack-riscv-none-elf-gcc-12.3.0-2/bin/riscv-none-elf- \
  DDR_BASE=0x00800000 DDR_BYTES=0x02000000 STRICT_DISPATCH=1 -j8
python3 .script/prepare-tinyml-project.py --live-rgb \
  --parameters iris_ws/RISC-V/rain_princess_8x2_lite_cache1024 \
  --output firmware/tinyml_style/build/rain_princess_rebuild/iris_ws
IRIS_PROJ_DIR="$PWD/firmware/tinyml_style/build/rain_princess_rebuild/iris_ws" .script/build-iris
```

`prepare-tinyml-project.py` 需要新的输出目录。突发 DMA 候选需另加 `--burst-dma`；默认仍采用已验证的标量搬运后端。历史 2.40 FPS 串行基线以已保存的位流 SHA256 和对应复制工程为准。任何新构建都须重新确认容量和时序，再仅下载 SRAM：

```sh
IRIS_PROJ_DIR="$PWD/firmware/tinyml_style/build/rain_princess_rebuild/iris_ws" .script/sync-iris jtag
```

停止 OpenOCD 后下载 SRAM，再重启官方 OpenOCD。`.script/run-tinyml-live` 加载 ELF、记录连续新帧、暂停 CPU 读取已显示银行的成对输入输出并恢复运行。每次新硬件/固件对比都先重新加载 SRAM；只复位 CPU 不能可靠清除捕获和银行所有权状态。`.script/check-tinyml-camera.py` 在主机计算相同输入的 BUILTIN_REF，仅用于验证。

独立 RTL 入口 `python3 tests/video/run_tinyml_video_tests.py` 覆盖全部采样字节、C3 DMA 和非法边界、HDMI 全帧像素和同步、银行切换、量化、总线延迟及读错误。原有视频回归记录为 `video-regression.log`，完整矩形路径回归为 `rectangle-rtl.log`。

本次均为 SRAM 加载，未写 Flash。断电后需要重新下载位流并加载 ELF。
