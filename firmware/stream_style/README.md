# 行流水 CNN 摄像头/HDMI 演示

此版本是为 Ti60 重新训练并实现的 One Last Kiss 小型学生 CNN。TFLite
是模型及 INT8 数值契约，`.script/compile-stream-model.py` 提取权重、偏置
和逐通道量化参数；推理由 `iris_stream_conv.v` / `iris_stream_cnn.v` 完成。
CPU 加载权重、分配非显示银行、采集、启动任务、处理真实完成中断和提交。
所有卷积、ReLU、量化及 NN2x 像素运算均在 RTL，运行时不依赖 TFLM。

## HDMI 单图左右对比

HDMI 已恢复 1920×1080、约 60Hz 输出；640×480 的试验输出已撤销。
完整 640×480 构图按 9/4 最近邻放大为 1440×1080，位于 x=240..1679，
两侧各 240 像素黑边，中线为 x=960。左半直接使用原生相机的屏幕坐标像素，
右半显示最近完成的 AI 帧。左侧不再绕过 640×480 张量再放大；右侧保留原来的
9/4 放大。左侧实时刷新，右侧约 30 FPS，因此移动物体存在正常的处理延迟，
左右两半不承诺来自同一采集帧。像素时钟为 148.75MHz，串行时钟 743.75MHz，
双像素读出时钟 74.375MHz，HDMI PLL 的 FB/slow/fast/half 分频恢复为
119/20/4/40。最终分屏图像之后叠加 CAM/WR/HDMI/AI 帧率及分辨率 OSD。

`iris_style_panels.v` 和 `iris_style_contour_panels.v` 在源像素坐标计算轮廓，
`iris_style_split_scaler.v` 负责放大。垂直消隐预取首四行，源行推进时预取
row+3；重复显示行不重复读取 DDR。三银行和帧边界切换保留，预取失败整行显示黑色。
显示回归入口为 `python3 tests/video/run_style_split_tests.py`。

## 原生相机调优

相机实际采集及去马赛克分辨率为 1920×1080。之前左侧也使用了 AI 输入的
640×480 数据再放大，丢失原生细节并放大颗粒。现在左侧 x=240..959 直接使用
原生相机像素；图像坐标和两侧黑边保持一致，右侧 AI 分辨率与放大算法保留。

进一步的共享源滤波在 `camera_raw_denoise_2px.v` 中实现，位置是 RAW 帧缓存
输出后、去马赛克前。每个 Bayer 像素只访问同色的上下左右相邻点（原生坐标
间隔 2），对这五点求中值；中心与中值差大于 24 时用中值替换孤立脉冲。
再将四邻点限制在引导值 ±12 内，以中心权重 4、四邻各 1 的平均值输出。
截限平均减少边缘两侧混色，四边在各自 Bayer 颜色平面复制。此阶段使用四行
RAW 缓冲，增加两条扫描行及八个时钟的延迟，没有整帧缓存或额外 DDR 访问。
后面的原生 RGB 高斯继续保留；两级处理均位于显示与 AI 输入的分支之前。

`camera_denoise_2px.v` 在去马赛克后、白平衡和 gamma 前，以原生分辨率执行
一次轻度 3×3 高斯滤波。滤波核为 `[1,2,1]ᵀ×[1,2,1]/16`，RGB 独立处理，
两轴加权后统一舍入，四边复制。它使用两行双像素缓存，不存整帧、不增加 DDR
或 CPU 图像运算；增加一条原生扫描行及三个时钟的延迟。AE/AWB 统计抽头与
颜色系数保持原值。RAW 降噪会自然影响其后的亮度统计值；自动曝光的低增益
恢复修复见下文，目标亮度仍为 72。降噪后的源画面也自然进入 AI 采样抽头。

本轮曾尝试在 640×480 张量上叠加中值和两级高斯，用户反馈过于模糊，已撤回。
`iris_style_preprocess` 默认恢复原有点采样，`ENABLE_GAUSSIAN/ENABLE_MEDIAN/
ENABLE_SMOOTH` 均为 0；实验分支仅供回归对照，不在当前位流中启用。
AI 模型权重、量化、颜色输出比例、固件推理调度没有改动。曾改过的轮廓阈值
已恢复 h=32/s=40，对应原来的增益与封顶值。

原生滤波验证入口为 `python3 tests/video/run_camera_denoise_tests.py --full`。
独立二维卷积参考检查整幅 1920×1080 的 RGB、四边、像素数、HS/VS/DE 时序；
小图回归还检查随机、黑白常量及边缘。分屏回归入口为
`python3 tests/video/run_style_contour_tests.py --panels`，使用逐像素变化的 RGB
输入，检查完整 1080p、左右接缝、三银行切换和 DDR 错误时左侧仍连续显示。
验证记录位于 `docs/validation/20261016-native-camera/`。

2026-10-16 实板观测 120 秒，AI 提交速率约 30.05 FPS，欠载、读错误及拒绝计数
均为 0。用户随后补充肉眼仍一直看到雪花、细节难以分辨，因此图像质量尚未通过
验收。当前只有单帧空间滤波，未实施跨帧降噪、运动补偿或几何防抖；运行统计
不能用于证明像素无噪声，雪花的具体来源仍需进一步诊断。

新增 RAW 级的参考验证入口为
`python3 tests/video/run_camera_raw_denoise_tests.py --full`，覆盖整幅 1080p；
`--source` 检查 RAW 滤波、BGGR 去马赛克和 RGB 高斯串接后的精确像素及同步，
包含随机、不同 Bayer 常量、黑白场、边缘和脉冲的连续帧。
合成噪声指标仅说明算法在测试输入上的效果，不代表实板雪花已经解决。
本版仍只有空间滤波，没有跨帧降噪或运动补偿。新记录位于
`docs/validation/20261016-source-raw-denoise/`。

用户随后读到左上角 FPS 下方的曝光 OSD：`E=200..410 G=A`，均为十六进制。
`G=A` 是增益表索引 10，对应约 24.640 倍模拟增益；曝光仅 512..1040 半行，
低于上限 2289。旧控制律在变亮时先缩短曝光，只有曝光到最小时才降增益，
因而可能一直保留高增益，放大共享源的彩色噪点。

`ae_ctrl.v` 现在在曝光余量允许时，降低一档增益并按相邻增益比延长曝光，
在同一个传感器 group hold 中写完增益和曝光后统一释放；亮度进入死区后也会
检查此恢复条件。保留曝光上下限、原目标、增益表和写后等待帧数，不强制降低
暗场所需的增益。这个修改属于传感器采集端，AI 参数及现有空间滤波不变。
曝光会延长，因此运动模糊仍需实屏观察；没有增加跨帧滤波或几何防抖。

`python3 tests/video/run_camera_ae_tests.py` 验证寄存器编码、原有曝光上下限，
以及带两帧反馈延迟的明暗闭环：上述亮度等效场景恢复到 G=6..8，补偿组的
曝光×增益变化小于 0.5%，恒定场景不反复调节，真正暗场仍允许 G=A。
仿真结果不代表实板雪花已解决；构建及实板记录位于
`docs/validation/20261016-low-gain-camera/`。
该曝光修复版已通过最终时序检查并仅加载 SRAM；连续 120 秒实板观测约
30.052 FPS，欠载、读取错误及拒绝均为 0。尚待用户确认新 E/G、左侧雪花和
运动拖影，图像质量未据运行统计判定通过。未连接会暂停 CPU 的调试器。

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

当前使用三组 DDR 银行，每组保留同帧输入和 CNN 输出：

| 银行 | 输入 | 输出 |
|---|---|---|
| 0 | 0x03000000 | 0x03400000 |
| 1 | 0x03200000 | 0x03600000 |
| 2 | 0x03800000 | 0x03a00000 |

每个张量仍为 1,228,800 字节。第三组只使用 DDR，不增加片上整帧 RAM。
APB0 0xf8100000 拒绝覆盖显示、待 VS 提交和推理中的银行；VS 回执后才释放
旧显示银行。采集启动和提交分别锁存银行编号，之后修改配置不改变 DMA 地址
或跨时钟提交邮箱。显示行标签包含完整两位银行号，原图与风格图同时切换。
DDR 为 128-bit、16 拍突发，整段 W 数据预先缓存且连续发送；背压时保持
数据稳定。错误/中止必须排空已发布事务；最终 B 响应及三个卷积阶段均
完成后才置完成标志及 PLIC USER A 中断。失败帧不会提交显示。

固件以非阻塞状态机管理 FREE / CAPTURING / CAPTURED / INFERENCING /
COMPLETE / PENDING / DISPLAYED。采集下一帧时可推理上一帧并显示更早的同帧
输入/输出对。模型、量化参数、CNN 运算和 640×480 分辨率不变。

APB 偏移 0x24 的银行 ABI 为 0x00030002；新增寄存器如下：

| 偏移 | 含义 |
|---|---|
| 0x40 | 流水所有权能力标识 0x49500301 |
| 0x44 | 已完成采集的银行有效位 [2:0] |
| 0x48 | 推理租约；写入 bit2=1 加银行号以申请，bit2=0 加同一银行号以释放 |
| 0x4c | 显示银行 [1:0]，bit2 表示有效 |
| 0x50 | 已锁存的采集银行 |
| 0x54 | 已锁存的待提交银行 |

每 30 次完整 VS 提交输出一组 IRIS LIVE 和 IRIS PERF 日志。后者包含
capture_ticks（申请采集至完整 DDR 写入）、invoke_ticks（启动至完成中断）、
commit_ticks（请求提交至 VS 回执）、period_ticks（相邻新画面提交间隔）及
overlap_ticks（该次推理与采集重叠的时间）。计时为 100MHz，除以 100000 得到
毫秒。UART 仅在发送 FIFO 有空间时排出日志，主循环不等待整行发送。
`.script/run-iris-style-demo --uart-only --elf firmware/stream_style/build/stream_style-live.elf`
配合 --bit-file、--seconds 和 --output 可生成提交率和各阶段耗时报告。

新增回归入口为 `python3 tests/video/run_style_pipeline_tests.py --display`，覆盖
三银行租约、第三银行采集和 CNN DMA 数值、银行切换整屏参考及读错误回退。
严格快照固件使用第三银行，以便检查新增 DDR 地址的完整输入/输出。

交叉工具链可通过 RISCV_PREFIX 指定，如 `riscv64-unknown-elf-`；默认在 PATH
查找工具链。构建命令使用 `--parameters firmware/stream_style` 可复用已提交的
权重参数头，仍须用 `.script/build-stream-boot --project-dir iris_ws` 更新启动
RAM 初始化文件后重新构建 FPGA。下文 15 FPS 实测记录属于此前串行版本。

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
`(abs(Gx)+abs(Gy)+8)/16`。默认 `h` 的阈值 64、增益 2、压暗上限 128；
`s` 阈值 96、增益 4、压暗上限 160，更侧重大边界。CNN 明暗压缩至约四分之一，
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
