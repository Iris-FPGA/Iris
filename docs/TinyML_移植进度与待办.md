# TinyML 移植进度与待办

更新时间：2026-10-08。当前目标是 640×480 神经风格输出至少 15 个新帧/秒、硬件预处理至少 30 帧/秒、1080p60 HDMI 对比界面、Flash 自启动。CPU 负责配置和调度，模型像素运算不允许计算回退。

**性能主线已更换为专用三层行流水CNN。真实摄像头完整输出与新TFLite整数参考逐字节一致，90秒实际新画面提交15.0233Hz、错误计数0，硬件Invoke约18.1ms。初版和最终镜像均通过600秒长测，真实AI FPS叠加及SRAM自动启动已完成；实屏效果等待用户确认，Flash仍未改。**

新模型2968字节、23.3472M MAC/帧；验证相对teacher PSNR25.067dB/SSIM0.61018，细节有损失。下面原6层/通用TinyML记录为历史对照，包含已失败的假设，不能据此判断当前新加速器状态。新路线证据与复现见[路线重评估](实时CNN_路线重评估.md)和[新固件说明](../firmware/stream_style/README.md)。

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

## 通用TinyML模型优化与历史工程配置

官方源码/运行库固定为 `../tinyml @ 96886fa0c73e25e6218db7d0863f84677cf65138`，Efinity 2026.1.132.4.5、xPack GCC12.3 RV32IM/ilp32。

优化模型从原始 teacher 蒸馏，COCO128 固定拆分 80 训练、16 校准、32 验证；低分辨率解码卷积、两条 skip、最后 1×1 Conv。24,000 步训练后 INT8 RGB 对 teacher 验证均值 PSNR26.019dB、局部 SSIM0.67323。该结果是近似 teacher 的质量比较，不是原始模型数值一致性，也不能宣称风格完全相同。

新模型为 `[1,480,640,4]`：RGB 加无作用第4通道，以适配 AXI 和 RTL 数据布局；输入 scale1/zero-point-128，输出 scale1.2273634672/zero-point-128。6 Conv、2 Add、2 NN2x，5960 字节，SHA256 `21ad447851ae878b135dee2480c33c41862e7fcc4c5889878f4fefbcb26aea47`。填充通道没有改变已验证的 RGB 输出。

- 模型：`one_last_kiss_style/models/c448_lowdec_skip_r0_refined_rgba_640_int8.tflite`。
- 官方生成器原始 C 数组与清单：`iris_ws/RISC-V/rgba640/`。
- 原始4×4首次布局需要257个存储块、62126逻辑单元，超限，未烧板。CPU缓存缩为1KiB、关闭未接线CPU I2C后仍超限；面积模式和关闭retiming也未解决，现已恢复speed/retiming2。DDRCLK_DOMAIN参数只影响Lite CPU。官方Java CLI --noDdrAClock --lowArea3去除标准CPU的DDR CDC，保留官方加密CPU模块，使RAM降到236个。最终通过项目dynparam关闭旧周期性AE UART日志，使逻辑降到59,740，完整时序和上板数值验证通过。top的ENABLE_LEGACY_UART_LOG默认1，当前项目设0；曝光、AWB、KEY2采样功能保留，旧周期性UART遥测在此调试位流中关闭。额外CPU参数记录在 `ip/SapphireSoc/iris_generator_options.json`，通过 `.script/gen-sapphire-soc` 完整复现，GUI直接重新生成不足以复现额外参数。
- 该阶段演示源配置切换官方 Conv4×2、CounterDepth640，`tinyml_core0_define.generated.v` 逐字节来自本次官方生成器。此配置的综合/上板结果独立于原始4×2结果。
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

## 新方案验收进度

1. 专用三层CNN完整640×480摄像头输入/输出与整数参考全部相等；初版600秒连续新帧率15.02477Hz，欠载/读错误/拒绝均0。
2. 最终自动启动及AI FPS位流已完成Efinity全流程：49,508 XLR/241 RAM/113 DSP，setup +0.005ns、hold +0.007ns。仅UART观察、无JTAG加载/启动程序，90秒15.02462Hz，错误0。独立AI FPS来自VS提交回执，仿真验证15 vsHDMI60及冻结后降0。
3. 最终位流再次导出真实摄像头完整输入/输出，TF2.20 BUILTIN_REF逐字节一致，不同字节0、最大误差0；该最终镜像600.035秒自动启动长测通过：新画面15.02460Hz，计数1→8820，错误均0。实屏持续更新、风格效果和撕裂仍等待用户观察。
4. OCR启动镜像已经随FPGA配置自动部署固件/权重，先复制DDR并核对FNV-1a。Flash尚未写，Flash回读与断电启动验证仍待完成。

用户此前选择先完成低帧率演示，随后确认从根本更换方法。性能主线现在是硬件适配小CNN与专用行缓存流水线，见[实时路线重评估](实时CNN_路线重评估.md)。工程实测已达到15fps；画质近似程度、实屏验收及Flash冷启动必须单独报告。以下为旧路线调试记录。

### 摄像头/HDMI演示调试

- 演示4×2位流（SHA256 `05a3e14c917c15014f474aeea43dc918f64d61d7950a0890ac47936cbb93ccde`）已完成Efinity综合、布局、时序、SRAM编程，57,623/60,800逻辑单元、232/256 RAM、50/160 DSP；setup最小+0.015ns、hold+0.026ns。旧4×4静态版本保留在固件build目录。
- 该演示位流独立运行静态640×480模型，全部10层严格硬件执行，输出仍逐字节相等；Invoke2.20527037秒。证据`demo4x2-clean-static-*`。HDMI重复输出60Hz不能替代新推理帧率。
- 原始演示固件切换TfLiteEvalTensor输入输出指针后，中间张量地址异常；加入DMA地址检查后会在危险写入前停止。缩小arena未解决。将可变解释器/Profiler控制数据迁入OCR，指针检查通过，但首层卷积后DDR中断数据仍出现图像值。根因未确认，不能声称已修好。证据`demo-live-ocr-control-*`。
- 当前改用硬件DMA把采集输入搬到静态验证过的arena，Invoke后再DMA搬到非显示输出银行，避免逐帧重绑定解释器指针。将官方中断标志、运行模式和加速器设置迁入OCR后，连续完成严格10层执行及成对提交；迁移是控制数据保护措施，不能作为DDR根因已修复的证明。
- 连续新画面提交实测0.365114帧/秒，Invoke约2.59秒；`validation/20261008-tinyml/demo-camera-pair-report.json`记录6次提交。旧两行预取版本长时间运行有显示欠载，已改为四行缓存、提前三行预取，完整帧/读错误恢复仿真与Efinity时序通过，板上持续零欠载仍待验证。
- JTAG冻结快照的输入与输出填充通道异常；随后改用FPGA只读DMA → CI寄存器 → UART原样导出，排除CPU/JTAG读取像素这一环节。`demo-hardware-stream-report.json`记录输入307200个像素中22506个填充字节异常；硬件计数与导出字节统计一致，固件已停止，未继续处理坏帧。不能接受摄像头数值或静默修补填充通道。
- 首个审计位流SHA256 `e5aee3e2e950e4311cc47de86d5f099810386076582399fb01227ff09067675a`，Efinity setup +0.013ns、hold +0.026ns，已加载SRAM；仅用于上述失败诊断。新增采集写端/DDR总线写端填充校验和可切换读写串行模式，正在构建以区分写入与并发读写问题。
- 双写端审计位流SHA256 `6154be006cff81f8b880de856c001aeaa9fcccd0b2194a28f8161633d1d909c9`，58,481/60,800 XLR、244/256 RAM、50/160 DSP，setup +0.011ns、hold +0.026ns。并发与串行两次导出均确认采集写端/DDR入口填充错误为0，但读回分别有22450/22612个异常字节；串行化未解决问题，保持默认关闭。证据`demo-ddr-{concurrent,serial}-stream-report.json`。
- `.script/probe-iris-style-dma` 在OCR运行已知64KiB RGBA图案测试，分别记录CPU写后校验、CI读取、DMA搬运、目的读取和一秒保留。**每次先重新加载SRAM**；失败运行后的热复位探测不能作为地址/容量结论。干净启动的7MiB→48MiB测试全部0误差，见`demo-style-dma-cold-probe.json`；这不是全256MiB容量验证。
- 同一位流冷启动，仅增加一次真实摄像头采集，随后上述图案测试立即失败，采集写端与总线校验仍0。已将故障范围缩到采集写事务触发后的DDR行为，见`demo-capture-trigger-probe.json`。
- 事务ID从E0改为10的比较位流SHA256 `e4b723ff01bb7d5227771faafcbc9dc139df2a9b5e6f3fa684c74d6089ab290f`，Efinity setup +0.027ns、hold +0.026ns。冷启动采集触发测试仍失败：源CPU/CI各16384个字全错、摄像头首64KiB有1342个填充异常，写端计数均0，见`demo-capture-id-probe.json`。ID修改没有解决故障，不能据此宣称原ID不合法。
- 采集器改为先缓存完整16拍，再连续输出WVALID；注册RAM读口保持背压下WDATA不变，短帧/溢出只填充失败事务并等待最后B响应，不发布成功。针对数据顺序、连续W、背压、最终响应和错误恢复的仿真通过；正在完整构建并等待冷启动上板对照，尚不能称为实板修复。
- 缓存初版被综合为寄存器，布局容量61875/60800超限；单独写端调整后仍61905超限，均未上板。按官方RAM推断模板合并单一注册读地址后，独立采集模块综合确认14个RAM、277个FF，包含异步FIFO与突发缓存，见`demo-capture-sdp-map.{log,rpt}`；正在进行整机容量/时序验证。完整RTL回归`demo-capture-staged-regression.log`全部通过。
- 完整突发缓存位流SHA256 `b1152a34dcabc33085b48d5b46452747863ab2ddd3965e2ab29ac16e8e1e34f8`，Efinity全流程PASS，58,445/60,800 XLR、251/256 RAM、50/160 DSP，setup +0.013ns、hold +0.026ns。冷启动真实采集后，CPU源校验、CI读取、DMA搬运、目的校验、一秒保留均0错误，摄像头首64KiB填充错误0，见`demo-capture-staged-probe.json`。这是采集触发故障首次通过对照；整帧及连续运行仍需单独验证。
- 同一位流冷启动完整摄像头输入/硬件结果经CI→UART原样导出，两帧各1228800字节，输入/输出填充审计均0，见`demo-capture-staged-stream-report.json`。TensorFlow2.20 BUILTIN_REF结果与硬件输出全部相等：不同字节0、最大误差0、MAE0，输出/参考SHA256均`69986c4cad116ef02d779499bc405ee0bb11d4365ac189882302f416e331029c`，见`demo-capture-staged-stream-parity.json`。对比PNG已生成；它证明导出图像与优化模型的同帧数值，HDMI物理显示仍待确认。
- 恢复`LIVE_SNAPSHOT=0`并冷启动连续演示，40.098秒记录14次交替银行提交，稳定新帧率0.365841781Hz，后续Invoke约2.59秒，所有记录欠载/读错误/拒绝为0，见`demo-capture-staged-live-report.json`。循环继续运行，Flash未写。完整缓存版本通过此前失败的采集触发、整帧和连续测试；尚未通过15fps。
- 独立30帧连续硬件采集测试，首尾29个完成间隔为48,252,030个100MHz CLINT tick，实测60.101098Hz；采集写端/DDR写入口填充计数均0，随后CPU/CI/DMA已知图案及保留全部0错误，最后摄像头首64KiB填充计数0，见`demo-capture-staged-30-probe.json`。这是不并行神经推理/风格面板的采集吞吐测试，不能代表神经新帧率或完整摄像头图像逐像素黄金对照；超过30fps采集指标。结束后冷启动恢复演示，见`demo-capture-staged-restored-*`。
- 恢复后的循环曾累计63次提交，20秒观察窗口错误计数均0；随后累计154次提交后冻结，用户移动/遮挡镜头确认HDMI两侧都不更新。新的UART观察无提交，CPU停在`add_drv`的完成标志轮询，PLIC pending=0、enable=0x40、priority=1、global_intr_id=12，驱动链表完整；DDR显示事务继续进行。现场见`demo-display-freeze-{state,flags,interrupt}.json`。短观察窗口不能证明长时间稳定，目前尚未确认是完成通知丢失还是加速器自身停顿。
- 增加被动CI/中断/DMA观察后，位流`e2f36260...`构建PASS，58,954 XLR/251 RAM/50 DSP，setup +0.027ns、hold +0.025ns。冷启动仅提交4帧后在同一Add处停止；硬件计数为37次启动、36次完成通知，未完成DMA事务0，最后CI=0x29、参数1/1，最后DMA写地址0xa736a0仍是上一个Conv的结尾，没有新的Add输出写事务；最后读地址0xb096c0也可能来自Add输入缓存预取，不能断言Add没有发起过读事务。这支持加速器启动/缓存状态问题，不能称为简单漏收IRQ；见`demo-observer-live-report.json`。该版ACK计数只正确覆盖Add，Conv确认的inputs_0=2，源码已修正观察解码，启动/完成计数不受影响。
- `run-iris-style-demo`现对超过15秒无新提交保存CPU/PLIC/APB证据并判失败，防止已提交若干帧但随后冻结的长测试误报通过。相同位流上每次官方`cache_reset()`后延迟1000个100MHz tick（10μs）的对照仍在32次提交后冻结：261次启动/260次完成通知、无待处理DMA，见`demo-cache-guard-live-report.json`。该假设未消除故障，生产固件已撤销间隔；实验源码仅保留在`probe/cache_reset_guard.cc`。
- 官方生成器明确支持`TINYML_CACHE="DISABLE"`，已生成模型/并行度相同、只有缓存模式改变的隔离版本，正在构建。该对照将确认Add的缓存路径是否为触发条件，不等同于已证明厂商IP内部根因。
- 发现共享仲裁器广播RLAST/RRESP，而TinyML接口原先在RVALID=0或resize拥有总线时仍直接转发这些标记。已将厂商接口RLAST/RRESP/BRESP限定在各自有效响应期间；完整有效拍的值不变。真实模块端口隔离仿真通过，恢复旧RLAST连接的负例立即失败，见`demo-qualified-response-{rtl,negative}.log`。位流`dee6b0c0...`全流程PASS、setup +0.030ns/hold +0.026ns；仍在4次提交后冻结，37次启动/36次完成/36次确认、无待处理DMA，见`demo-qualified-response-live-report.json`。隔离措施没有消除本次Add停顿，不能称其为冻结根因。
- 官方关闭缓存对照位流`9588031a...`已构建PASS：55,588 XLR/229 RAM/47 DSP、setup +0.011ns/hold +0.026ns，已加载SRAM并开始600秒连续对照；固件显式缓存复位和计数读取已按硬件发现的cache_en跳过，支持该官方配置。缓存启用时继续执行原有操作。此位流尚不含响应标记隔离，保持关闭缓存这一项独立对照。
- 开始独立目录4×4速度比较，官方生成器只改STD_OUT_PARALLEL 2→4，模型保持相同。首次speed/retiming2综合通过但容量62,931/60,800 XLR超限、255/256 RAM、66/160 DSP，布局失败，未上板；证据`speed4x4-build.log`、`speed4x4-generator-manifest.json`。当前板端保持已验证4×2演示；正在比较area/LUT打包/运算共享参数，未获得4×4演示吞吐成绩。
- 演示固定银行：input 0x03000000/0x03200000，output 0x03400000/0x03600000；APB0 0xf8100000，提交在VS生效并回执后才可复用旧银行。
- 当前演示保留曝光/AWB，关闭旧周期UART日志；KEY2/UART C调试缩略图从96×54改为48×27以节省RAM，默认非演示模式仍为96×54。
- 摄像头真实图像数值已通过一个整帧参考对照；长时间连续演示冻结，HDMI尚未验收，不烧Flash。
