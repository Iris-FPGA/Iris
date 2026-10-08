# 行流水 CNN 摄像头/HDMI 演示

此版本是为 Ti60 重新训练并实现的 One Last Kiss 小型学生 CNN。TFLite
是模型及 INT8 数值契约，`.script/compile-stream-model.py` 提取权重、偏置
和逐通道量化参数；推理由 `iris_stream_conv.v` / `iris_stream_cnn.v` 完成。
CPU 加载权重、分配非显示银行、采集、启动任务、处理真实完成中断和提交。
所有卷积、ReLU、量化及 NN2x 像素运算均在 RTL，运行时不依赖 TFLM。

## 模型及质量

选择 `one_last_kiss_style/models/micro4_d2_rgba_640_int8.tflite`，2968 字节，
SHA256 `e4a45f1d9314654565f3300978d8a7b8843fc0c0687c454c4b6e3b47e0f05386`。
输入/输出均为 NHWC INT8 `[1,480,640,4]`，第四输入通道固定为 -128。
三层均为 4 通道：3×3 stride2 → 3×3 dilation2 → 1×1，然后 NN2x。
BN 折叠进卷积参数，每层融合 ReLU 和 gemmlowp 双重舍入。
输出 scale=1.2276244163513184、zero point=-128，显示 Q24=20596120。
卷积 23,347,200 MAC/帧，内部特征为 320×240；最终输出为 640×480。

固定 COCO128 拆分为 80 训练、16 校准、32 验证；6000 步训练。
相对于原风格 teacher 的验证均值 PSNR=25.067dB、局部 SSIM=0.61018。
这是近似风格的质量指标；板端数值相等是相对于这个新学生模型。
训练目标缓存绑定 teacher/source/image 哈希，不允许混用未知缓存。
候选质量、数据清单和同帧对照位于 `docs/validation/20261008-tinyml/`。

## 复现

```sh
# 使用项目现有 .venv-style；当前参数头已保存在固件目录。
.venv-style/bin/python one_last_kiss_style/stream_student.py --candidate micro4_d2
.venv-style/bin/python one_last_kiss_style/export_stream.py --candidate micro4_d2
.venv-style/bin/python .script/compile-stream-model.py \
  one_last_kiss_style/models/micro4_d2_rgba_640_int8.tflite \
  firmware/stream_style/build/native-d2 --width 640 --height 480 --verify-tflite
.script/build-stream-firmware --parameters firmware/stream_style/build/native-d2
.script/build-stream-firmware --parameters firmware/stream_style/build/native-d2 --snapshot
python3 tests/video/run_video_tests.py
.script/build-iris
```

项目参数为 ENABLE_STYLE_DEMO=1、ENABLE_STREAM_CNN=1、STREAM_DILATION=2，
STYLE_SCALE_Q24=20596120。通用厂商 TinyML 加速器在该配置中不实例化，
保留 CPU、摄像头、DDR、HDMI、曝光和 AWB。

通过完整时序检查后 `.script/sync-iris jtag` 仅加载 SRAM。使用官方
OpenOCD 与 UART，通过 `.script/run-iris-style-demo --elf ... --bit-file ...`
记录 VS 已确认的新画面提交率；60Hz HDMI 重复输出不能作为 CNN 帧率。
`--attach` 只观察正在运行的固件。`--entry 0xf9000000` 用于加载并验证 OCR
自启动 ELF；普通演示 ELF 的入口为 0x00800000。

数值验收使用 `.script/export-style-uart --elf ...snapshot.elf --bit-file ...`
导出完整输入及输出，再用 `.script/verify-style-snapshot.py --model ...`
逐字节核对。像素经硬件只读 DMA、CI 寄存器和 UART 原样导出。

## 总线、银行及完成条件

输入银行为 0x03000000 / 0x03200000，输出为 0x03400000 / 0x03600000。
APB0 0xf8100000 只允许写非显示银行；VS 提交回执后才释放旧银行。
DDR 为 128-bit、16 拍突发，整段 W 数据预先缓存且连续发送；背压时保持
数据稳定。错误/中止必须排空已发布事务；最终 B 响应及三个卷积阶段均
完成后才置完成标志及 PLIC USER A 中断。失败帧不会提交显示。

自研 CNN custom0 function ID 为 `(func7<<3)|func3`：

| ID | 作用 |
|---|---|
| 0x240 | 发现 0x49430101 |
| 0x241 | 配置输入/输出地址 |
| 0x242 | 读取 H/W |
| 0x243 | 读取所选层输出像素数 |
| 0x244 | 写参数 `(layer<<8)|index`、value |
| 0x245 | 启动 |
| 0x246 | 状态 busy/done/error/parameters_ready；错误码在 [15:8] |
| 0x247 | 中止并排空 |
| 0x248 | 输入填充通道错误计数 |
| 0x249 / 0x24a | 读/写拍数 |
| 0x24b | CNN 周期数 |
| 0x24c | 确认完成，仅空闲时允许 |

每层 52 个参数字：0..35 为 9 个 tap 的 4×4 INT8 权重；36..39 偏置；
40..43 量化 multiplier；44..47 shift；48/49 输入/输出 zero point；50/51
激活上下限。当前编译器拒绝不支持的正 shift，不静默生成错误 RTL 参数。

## 自动启动及验收边界

`.script/build-stream-boot --project-dir iris_ws` 只更新 RAM 初始化文件，
需重新构建 FPGA。4320 字节 OCR 镜像包含启动代码及 4116 字节固件/权重，
不更改 Sapphire CPU 架构。启动后复制到 DDR，刷新缓存、核对 FNV-1a，
等待摄像头初始化，再跳入正常固件；失败停在 OCR 并写诊断字。
它允许固件随 FPGA 配置从 Flash 自启动，无需另外分配 SPI 软件区。

2026-10-08 初版实板完整输入/输出 1,228,800 字节与 TF2.20 BUILTIN_REF
完全相等；90 秒新帧率 15.0233Hz，Invoke 约 18.1ms，显示错误计数 0。
FPS 叠加版本完整时序通过，49,508/60,800 XLR、241/256 RAM、113/160 DSP，
最小 setup +0.005ns、hold +0.007ns。长测、实屏效果及自动启动分别记录；
SRAM 和 OCR loader 的验证不能代替 Flash 回读或断电启动验收。

最终自动启动镜像 SHA256
`c832415c9d28990b59065345f879dd0c269c241eda5aaf79e2371e0878cf7963`。
完整摄像头再次导出核对全部相等；UART-only600.035秒测试新帧率15.02460Hz、
显示计数1→8820、全部错误0，期间没有OpenOCD/JTAG控制或固件下载。
当前板子继续运行此SRAM镜像，Flash保持原有版本。验收汇总为
`docs/validation/20261008-tinyml/stream-realtime-acceptance.json`。
APB9的0x000a0001是保留的显示接口标识；其中旧的10层数字不代表新CNN层数。
