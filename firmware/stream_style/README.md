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
ENABLE_STYLE_VISIBILITY=1、ENABLE_STYLE_CONTOUR=1，
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
需重新构建 FPGA。当前 4664 字节 OCR 镜像包含启动代码及 4460 字节固件/权重，
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
该版本作为增强前的基线保留，该阶段没有写 Flash。基线验收汇总为
`docs/validation/20261008-tinyml/stream-realtime-acceptance.json`。
APB9的0x000a0001是保留的显示接口标识；其中旧的10层数字不代表新CNN层数。

## 显示对比度与线条增强

以下为保留的 ABI1 对比度/加粗方案，ENABLE_STYLE_CONTOUR=0 时可选。
2026-10-08 用户确认风格已显示，但白色背景占比高、线条较浅。新增显示后处理
`iris_style_ink.v`，默认模式 2：适度压暗笔画，并扩展约一个输出像素。
RGB 使用共同的压暗量，保留通道差异直至饱和；较浅背景保持白色。
模型、权重和 DDR 中的原始 INT8 输出不变，CPU 不参与图像计算。

| UART 单字符 | 模式 | 效果 |
|---|---|---|
| n | 0 | 原显示效果 |
| c | 1 | 适度提高对比度 |
| h | 2 | 对比度 + 轻度加粗，默认 |
| s | 3 | 更强对比度 + 轻度加粗 |

固件每个完成帧最多读取一个命令，APB 邮箱在 HDMI VS 生效，避免半帧切换。
寄存器 0xf8100034 是请求模式，0xf8100038 bit0 表示等待 VS 回执，
0xf810003c 返回增强能力标识 0x494b0001。

加粗对 RGB INT8 使用 2×2 最小值：当前像素、左邻、下一行及下一行左邻。
复用现有四个预取行缓存，第一列和最后一行夹边，下一行缺失时回退当前行；
前一行可能被预取覆盖，不能用于邻域。显示延迟从 3 增至 5 个双像素时钟，
同步信号、背景和左侧原图同时延迟。没有新增 RAM、DSP 或 DDR 事务。

增强显示故意与原始 CNN RGB 不同。上文 PSNR/SSIM 是原模型验证指标，
不能作为增强画面的质量指标；它也不能恢复小模型已经丢失的细节。
同帧对照由 `.script/render-style-visibility.py` 从原样硬件导出生成，
是离线显示参考，不是 HDMI 屏幕截图。

增强版构建、仿真、编程和 UART 连续运行证据位于
`docs/validation/20261008-style-visibility/`。仅加载 SRAM，实屏清晰度由用户确认。

## 主轮廓显示（ABI2）

用户确认 ABI1 的轮廓已经清楚，但噪点同时加深，并选择“突出主轮廓，减少细碎纹理”。
当前项目选择 `ENABLE_STYLE_CONTOUR=1`：轮廓来自原图经过平滑的亮度梯度，
颜色来自原始 CNN 输出。这是混合显示后处理，不是学生模型的原始 RGB 输出，
也不能宣称 CNN 本身的精度已提升。`n` 档仍直接显示 CNN 原结果。

亮度使用 `(R+2G+B+2)/4`。Gaussian3 与 Sobel3 合成 5×5 整数卷积：
平滑系数 `[1,4,6,4,1]`，导数系数 `[-1,-2,0,2,1]`。梯度为
`(abs(Gx)+abs(Gy)+8)/16`。默认 `h` 的阈值 32、增益 2、压暗上限 128；
`s` 阈值 40、增益 4、压暗上限 160，更侧重大边界。CNN 明暗压缩至约四分之一，
保留 RGB 通道差异，叠加轮廓压暗量；弱梯度不继续加深。

| UART 单字符 | 当前 ABI2 效果 |
|---|---|
| n | 原 CNN 显示 |
| c | 原 CNN 适度提高对比度 |
| h | 平滑主轮廓引导神经颜色，默认 |
| s | 更强、更稀疏的主轮廓 |

`iris_style_contour_panels.v` 保留原四个 RGB 预取行缓存，新增六个灰度缓存：
其中五行组成居中的邻域，第六行用于预取 row+3，不覆盖仍在使用的 row-2。
灰度在已有输入 DDR 响应上计算，没有增加 DDR 事务。邻行标签必须匹配行号和
画面银行；缺失邻行回退当前行，第一/最后两行、两列复制边界。
`iris_style_contour.v` 每时钟处理两像素，含邻域等待的面板总延迟为 7 个时钟。
APB 能力标识为 0x494b0002，模式请求仍在 VS 生效。

独立二维卷积参考验证 10,240 个单元测试向量。整幅 1080p 两帧、银行切换、
模式切换及读错误回退的逐像素验证和官方构建证据位于
`docs/validation/20261008-style-denoise/`；同帧参考可用
`.script/render-style-visibility.py PREFIX --contour --mode 2 --output PREVIEW.png` 生成。
这是离线参考，不是实屏截图。最终运行结果见该目录的验收文件。

当前主轮廓位流 SHA256 为
`6f3a793a4dd0104659be0319e43e9a0c19a4135e84094e329e26fb70edee18c4`。
官方 Efinity 全流程通过，52,995/60,800 XLR、253/256 RAM、113/160 DSP，
100MHz 最小 setup +0.027ns、hold +0.026ns。仅 UART 观察 240.161 秒，
完整新画面提交率为 15.029116Hz，计数 1→3390，欠载/读错误/拒绝全部为 0。
`n/c/s/h` 切换请求均已在板端日志核对，最终恢复默认 `h`。

已按用户要求使用官方 JTAG2SPI 桥写入 W25Q64 Flash。第一次回读校验不一致，
官方编程器调整等待时间后自动重写同一镜像，最终 `Flash verify successful`。
完整日志为 `docs/validation/20261008-style-denoise/program-flash.log`。
断电启动仍待实物操作及 UART/实屏确认；Flash 校验成功不能替代该项。
固件保留的旧启动横幅含 `SRAM only` 字样，不能据此判断配置来源，
应以编程日志和断电启动证据区分 SRAM/Flash。
等待 300 秒未观察到重新上电后，已将同一镜像加载回 SRAM 恢复演示，
不改写 Flash；随后 UART 连续运行复验通过，默认模式 2、能力 ABI2、错误 0。
这次恢复演示的启动记录仅作为 SRAM 证据，不能算 Flash 冷启动通过。
