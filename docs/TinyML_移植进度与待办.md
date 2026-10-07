# TinyML 移植进度与待办

更新时间：2026-10-07。当前目标是 640×480 神经风格输出至少 15 个新帧/秒、硬件预处理至少 30 帧/秒、1080p60 HDMI 对比界面、Flash 自启动。CPU 负责配置和调度，Conv/Add/Resize 不允许计算回退。

**原始128×128模型和优化后的640×480模型都已在Ti60F225完成严格硬件推理，与各自TFLite整数参考逐字节一致。640×480实测单次Invoke为1.3799秒，未达到15个新风格帧/秒；摄像头实时接入、对比显示和Flash自启动尚未完成。**

## 已验证的板端结果

- 原始模型 125336 字节，16 Conv、5 Add、2 Resize，23 层全部为硬件模式。Conv/Add 为官方 STANDARD，Resize 为 Iris RTL `IRIS_RESIZE_HW`。
- 确定性梯度/棋盘格输入，49152 字节输出完全一致：最大误差 0、MAE 0、不同字节 0；FNV-1a `8d500404`，输出 SHA256 `eb1b0624270391f6c627278100817aca99587a82fe594527efb3646fee3919e8`。
- 本轮约 4.40 秒，包含逐层 UART 打印，**不满足 15 fps**；后续 profiler 已改为 Invoke 后打印，需重新测量。
- 对应证据：`validation/20261007-tinyml/cache-restored-static-strict-{uart.log,debug.json,output.bin}`。只证明一个静态输入的原始模型数值，不证明摄像头质量或实时输出。
- 该位流使用官方生成的 Sapphire OCR16KiB、I/D Cache4KiB、100MHz、Conv4×2；完整 Efinity 时序最小 setup +0.039ns、hold +0.014ns。只烧 SRAM，Flash 仍保留旧固件。

### 640×480板端验证

- 优化模型6 Conv、2 Add、2 NN2x，10层全部硬件模式；Conv/Add为官方STANDARD，NN2x为IRIS_RESIZE_HW。
- 完整读回1,228,800字节，与TensorFlow2.20 BUILTIN_REF完全一致：不同字节0，最大误差0，MAE0；FNV `3830f80b`，输出SHA256 `828b3c885079d22f515ac4c6ac2d00e5d5aed96dd01259ba00c059192e5a8962`。
- 单次Invoke为137,987,371个100MHz CLINT tick，即1.37987371秒，倒数约0.725次/秒。profiler在Invoke结束后打印，耗时不含逐层UART输出。该静态测试没有测量连续新帧率，不能作为15fps验收。
- 前两层卷积约808.6ms和266.1ms，占Invoke约77.9%。另一次halt/resume诊断的25个CPU PC样本全部位于官方conv_drv等待中断标志的循环（0x8174bc/0x8174c0）；支持优先检查硬件卷积及DDR访存，不代表已经区分硬件内部计算与访存耗时。该采样扰动了时序，不能作为吞吐成绩。
- Efinity map/interface/pnr/pgm全部PASS；setup最小+0.030ns、hold最小+0.024ns；59,740/60,800 XLR（98.26%），236/256 RAM，54/160 DSP。
- 只加载SRAM，Flash未改。位流SHA256 `885b2f7dfa6abd83eeecc348f692e2930b17606b3a4afdf11b24a586d324d23b`；固件SHA256 `f401788c351982363f7265f0b43c609e1d126a9cbc85482eb36da4c3b8dd3556`。
- 证据：`validation/20261007-tinyml/rgba640-static-strict-{debug.json,uart.log,output.bin}`、`rgba640-style-profile-{build,program}.log`和`rgba640-cpu-samples.json`。数值相等是与优化模型比较，不表示优化模型与原始teacher完全相同。

## 已修复的问题

1. DDR 写仲裁在 WLAST 后、B 返回前继续接收后续 W 数据，允许其领先下一次 AW，造成 O3 unroll 写入和模型节点损坏。已在 WREADY/数据提交/越界吞吐路径阻断已结束的 burst；独立 AW/W 流测试可复现旧实现失败，修复实现通过。
2. 单地址 DDR bridge 的 AW/AR 选择在背压下可能切换。已保持选中地址直到握手，随机背压测试及旧实现负向回归通过。读写事务串行化仅为默认关闭的诊断参数，其板端版本曾停滞，不能用作验收。
3. CPU 的窄单拍访问需要转换到原生 128-bit DDR 行，同时保留 WSTRB 和全行 RDATA，由 Sapphire 上游选择字节。
4. 官方 TinyML archive 执行 Sapphire 数据缓存刷新指令 `0000500f`。关闭 CPU 缓存会触发非法指令；目前使用官方生成器恢复缓存，并在自研 DMA 边界执行 CPU cache 写回/失效与 TinyML cache reset。
5. 控制栈放入 OCR `[f9002000,f9004000)`；TFLM Init/Prepare 错误向上传递，严格 Conv/Add 拒绝 OP_BYPASS 和 CPU fallback，内部浮点与广播 Add 在契约阶段拒绝。

不带 CPU cache 的修复位流曾在 `f00000` 与 `c4d000` 两个 64KiB DDR 窗口通过 O3/unroll、全宽/半字/字节、稀疏邻居保护、随机散写、保留和 DDR 取指压力测试；证据是 `write-boundary-unrolled-probe-{1,2}.json`。

## 模型优化与当前工程配置

官方源码/运行库固定为 `../tinyml @ 96886fa0c73e25e6218db7d0863f84677cf65138`，Efinity 2026.1.132.4.5、xPack GCC12.3 RV32IM/ilp32。

优化模型从原始 teacher 蒸馏，COCO128 固定拆分 80 训练、16 校准、32 验证；低分辨率解码卷积、两条 skip、最后 1×1 Conv。24,000 步训练后 INT8 RGB 对 teacher 验证均值 PSNR26.019dB、局部 SSIM0.67323。该结果是近似 teacher 的质量比较，不是原始模型数值一致性，也不能宣称风格完全相同。

新模型为 `[1,480,640,4]`：RGB 加无作用第4通道，以适配 AXI 和 RTL 数据布局；输入 scale1/zero-point-128，输出 scale1.2273634672/zero-point-128。6 Conv、2 Add、2 NN2x，5960 字节，SHA256 `21ad447851ae878b135dee2480c33c41862e7fcc4c5889878f4fefbcb26aea47`。填充通道没有改变已验证的 RGB 输出。

- 模型：`one_last_kiss_style/models/c448_lowdec_skip_r0_refined_rgba_640_int8.tflite`。
- 官方生成器原始 C 数组与清单：`iris_ws/RISC-V/rgba640/`。
- 原始4×4首次布局需要257个存储块、62126逻辑单元，超限，未烧板。CPU缓存缩为1KiB、关闭未接线CPU I2C后仍超限；面积模式和关闭retiming也未解决，现已恢复speed/retiming2。DDRCLK_DOMAIN参数只影响Lite CPU。官方Java CLI --noDdrAClock --lowArea3去除标准CPU的DDR CDC，保留官方加密CPU模块，使RAM降到236个。最终通过项目dynparam关闭旧周期性AE UART日志，使逻辑降到59,740，完整时序和上板数值验证通过。top的ENABLE_LEGACY_UART_LOG默认1，当前项目设0；曝光、AWB、KEY2采样功能保留，旧周期性UART遥测在此调试位流中关闭。额外CPU参数记录在 `ip/SapphireSoc/iris_generator_options.json`，通过 `.script/gen-sapphire-soc` 完整复现，GUI直接重新生成不足以复现额外参数。
- 当前演示源配置已切换官方 Conv4×2、CounterDepth640，`tinyml_core0_define.generated.v` 逐字节来自本次官方生成器。此配置的综合/上板结果独立于原始4×2结果。
- 固件 `MODEL_PROFILE=original|rgba640` 明确选择模型；原始 arena2MiB，新模型4MiB（实际使用3,688,092字节），均从8MiB DDR 窗口开始。诊断临时窗口已移动到7MiB，避免覆盖大 arena。
- 82.33M MAC 对100MHz×16 MAC仅给出理想计算上限19.43fps，**不含 DDR/Resize/Add/调度开销，不能作为15fps实测证据**。
- 640×480的TFLite BUILTIN_REF黄金输出已生成，`golden-rgba640.json`记录身份及板端逐字节一致结果。

## RTL 与工具

`iris_resize2x.v` 支持 INT8 NHWC C4/8/16/32、原始模型形状、错误与中止排空，响应返回后才报告完成。CI function IDs 0x200..0x206；本轮新增0x208字节原样DMA搬运，模型原2x命令语义保留；vendor 与用户 DMA 互斥，拒绝未决事务时切换。

`iris_style_preprocess.v` 已实现1080p RGB双像素输入：中心1440×1080裁剪，再以 floor(dst×9/4) 得到640×480，量化为INT8 RGBA、逐行/逐帧标记。逐像素独立参考覆盖完整帧、短帧、禁止/重新启动；已接入一次性采集 DMA 和整机；实板已成功采集一帧，尚未验证连续≥30fps预处理。

`iris_style_dequant.v` 对新模型INT8输出以Q24乘法/四舍五入/饱和转换RGB，1024个独立浮点参考输入已通过，已接入双640×480对比显示模块；完整帧、DDR背压、行读取错误恢复与帧边界双缓冲切换仿真通过，实板视觉待验证。

复现入口：

```sh
python3 tests/video/run_video_tests.py
.script/build-iris
.script/gen-tinyml-model.py --help
.script/build-tinyml-firmware check-model MODEL_PROFILE=original
.script/build-tinyml-firmware check-model MODEL_PROFILE=rgba640
```

板端工具使用官方 OpenOCD Tcl6666，加载与读回由 `.script/run-tinyml-bringup` 完成；DDR 专项由 `.script/probe-iris-ddr` 完成。`.script/sync-iris jtag` 仅写 SRAM。具体依赖、地址与 CI 说明见 `firmware/tinyml_style/README.md`。

## 仍需完成

1. 640×480硬件数值、资源和时序已通过；实际吞吐仍差约20.7倍，优先定位卷积数据复用/DDR访存，依据实测优化，不得以HDMI重复输出率代替新神经帧率。
2. 摄像头预处理接入 DMA，输入/输出多缓冲所有权与完整提交，证明预处理30fps及神经新帧15fps。
3. RTL 输出反量化、1080p60左右对比界面、切换和状态，独立验证撕裂与真实显示质量。
4. Flash CPU/model loader、自启动推理循环、正式烧录读回与断电重启验证。

用户已选择先完成现有低帧率摄像头/HDMI演示，再优化速度。15fps及Flash自启动仍属于原题未完成指标，低帧率演示不能作为整题验收。

### 摄像头/HDMI演示调试

- 演示4×2位流（SHA256 `05a3e14c917c15014f474aeea43dc918f64d61d7950a0890ac47936cbb93ccde`）已完成Efinity综合、布局、时序、SRAM编程，57,623/60,800逻辑单元、232/256 RAM、50/160 DSP；setup最小+0.015ns、hold+0.026ns。旧4×4静态版本保留在固件build目录。
- 该演示位流独立运行静态640×480模型，全部10层严格硬件执行，输出仍逐字节相等；Invoke2.20527037秒。证据`demo4x2-clean-static-*`。HDMI重复输出60Hz不能替代新推理帧率。
- 原始演示固件切换TfLiteEvalTensor输入输出指针后，中间张量地址异常；加入DMA地址检查后会在危险写入前停止。缩小arena未解决。将可变解释器/Profiler控制数据迁入OCR，指针检查通过，但首层卷积后DDR中断数据仍出现图像值。根因未确认，不能声称已修好。证据`demo-live-ocr-control-*`。
- 当前改用硬件DMA把采集输入搬到静态验证过的arena，Invoke后再DMA搬到非显示输出银行，避免逐帧重绑定解释器指针。正在综合、仿真和上板验证；CPU不处理图像像素，Conv/Add/NN保持严格硬件执行。
- 演示固定银行：input 0x03000000/0x03200000，output 0x03400000/0x03600000；APB0 0xf8100000，提交在VS生效并回执后才可复用旧银行。
- 当前演示保留曝光/AWB，关闭旧周期UART日志；KEY2/UART C调试缩略图从96×54改为48×27以节省RAM，默认非演示模式仍为96×54。
- 尚无摄像头真实图像推理数值/连续提交/HDMI视觉通过结论；不烧Flash。
