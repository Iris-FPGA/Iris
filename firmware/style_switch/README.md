# KEY3 切换两种现有风格

用户已取消双风格切换，要求恢复测试前的单风格版本。该候选未通过
HDMI 实物验收，不应部署。完整原版 Flash 已回写并通过回读校验，原 FPGA 镜像已启动；
实屏恢复仍待确认，恢复记录见
[验证说明](../../docs/validation/20261024-style-switch/README.md)。
以下内容保留为未验收实现的构建记录。

此构建把现有 **One Last Kiss 640×480 轮廓增强版**与完整 **Rain Princess
128×128 RGB 模型**保存为 Flash 中的两个 FPGA 镜像。默认上电进入 One Last
Kiss；每次按下并松开 **KEY3**，切换到另一个风格。切换会重新配置 FPGA、
初始化摄像头和 DDR，HDMI 会暂时黑屏。不是在一个视频帧内即时切换。

两套原有模型、量化、颜色、轮廓及 HDMI 几何各自保留。KEY0/KEY1 继续调曝光；
KEY2 保留原来各自镜像的行为。切换重新启动整套系统，临时曝光补偿和截图
不跨镜像保存。KEY3 不再兼作 UART 输出源选择，串口固定连接 CPU。

One Last Kiss 使用随附的 `one_last_kiss_contour.bin`，即测试前板上已验证的
6364 字节控制固件，而不在双镜像构建时重新编译。其来源、原启动器的
FNV `3709eec3`、SHA256 和参数表绑定记录在同名 JSON 中；624 字节神经
网络参数与当前 `stream_model.h` 逐字节一致，保留原来的控制流程和参数。
更换模型参数时必须同时更新并重新验证该控制固件，构建脚本会拒绝参数不匹配。

20 ms 消抖，一次按下只触发一次；切换后需要稳定松开才重新接受按下，避免
长按导致两个镜像反复重启。内部重配置错误会阻止自动再次触发。

## 构建

使用 Efinity 2026.1、RISC-V RV32IM 工具链及包含 numpy、flatbuffers、tflite 的
Python 3 环境。从仓库根目录执行，输出目录必须尚不存在：

```sh
export EFINITY_HOME=/path/to/efinity/2026.1
export RISCV_PREFIX=/path/to/riscv-none-elf/bin/riscv-none-elf-
python3 .script/build-style-switch \
  --model-python /path/to/model-python \
  --output firmware/tinyml_style/build/style-switch
```

该脚本不接触开发板。它复制两个独立 Efinity 工程，构建各自的固件和启动
RAM，再检查时序，调用厂商的 Remote Update Flash Image 合并工具。两个镜像
均可访问相同的重配置表。Rain Princess 固件及完整模型保存于 Flash
`0x600000`，由现有 Sapphire SPI0 以只读方式拷贝到 DDR `0x00800000`；
启动器先发送 `ABh` 解除配置后的 Flash 休眠并等待 1 ms，校验 DDR 副本的
长度和绑定到构建的 FNV 后才跳转执行。现有 Sapphire SPI 控制器的接收
采样有两个外设时钟的延迟，MISO 经过 3 个 core 时钟寄存后送入控制器，
保持被采样位；直接连接会把 JEDEC `EF6017` 读成 `DEC02E`。
Flash 引脚使用板上现有 J6 对应的 1.8 V 配置引脚，无需额外接线。

脚本支持 `--stage prepare|build|package` 分段执行。`manifest.json` 记录模型、
参数、固件、两个位流及合并镜像的哈希、Flash 布局和项目位置。
标准 `.script/build-iris` 继续构建原单镜像；本功能通过生成工程中的
`ENABLE_STYLE_SWITCH=1` 启用。

## 烧录

```sh
.script/sync-style-switch firmware/tinyml_style/build/style-switch
```

它会先核对清单和两份时序报告，再通过板载 JTAG bridge 写入 Flash，必须得到
`Flash verify successful` 才报告写入成功。随后必须将开发板断电重上电，
从 Flash 主动启动，默认进入 One Last Kiss。厂商内部重配置接口要求主动
配置模式；直接 JTAG / SRAM 启动可以单独调试 CPU 和视频，但不能据此
验收 KEY3 切换。脚本不会再加载被动模式启动位流代替此步骤。
SRAM 单独加载 Rain 镜像时，也必须先有与启动器匹配的 Flash 固件区，
或单独加载相同的 ELF 进行调试；后者不构成 Flash 自启动验证。

验证按键状态机：

```sh
python3 tests/video/run_style_switch_tests.py
python3 tests/video/run_style_boot_spi_tests.py
```

调试寄存器 `0xf8110070` 的高 16 位为 `0x4952`；bit6 为当前镜像
（0=One Last Kiss，1=Rain Princess），bit5 为配置错误，bit4 为 CONFIG，
bit3 为 ENA，bit2 为按键已就绪，bit1:0 为同步后的 KEY3。
写入精确值 `0x49525357` 可触发同一重配置状态机，用于实板自动往返测试。
它验证重配置路径，不能代替真人按键验证。实际风格图像及冷启动验收要另外
记录。

芯片接口与镜像布局依据厂商 [AN 010 v2.5](https://www.efinixinc.com/docs/an010-using-internal-reconfiguration-feature-v2.5.pdf)。
