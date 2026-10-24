# One Last Kiss 轮廓增强版 / Rain Princess 按键切换

用户已取消本任务，要求恢复测试前的单风格 Flash。以下双风格结果保留为失败候选的验证记录。

用户选择：现有 640×480 One Last Kiss 轮廓增强 student 与完整 128×128
Rain Princess；保持各自已有量化、视频几何和显示处理。

采用 Ti60 内部重配置，两个完整镜像位于同一片 Flash。KEY3 一次按下切换
一次，20 ms 消抖；镜像启动后必须先松开按键，避免长按反复重启。切换期间
HDMI 中断，摄像头与 DDR 重新初始化。操作与复现见
[启动与构建说明](../../../firmware/style_switch/README.md)。

构建环境：Efinity 2026.1、Ti60F225 I3、100 MHz core；两套镜像分别检查
23 组时钟关系，均通过 setup/hold。One Last Kiss 使用 seed 1，Rain Princess
使用 seed 4、placer effort 3。SPI 采样修正后，seed 2/3/5 的 Rain Princess
分别有 -0.324/-0.007/-0.107 ns setup 违例，均未作为最终镜像烧录。

| 镜像 | setup 最小裕量 | hold 最小裕量 | RAM10 |
| --- | ---: | ---: | ---: |
| One Last Kiss 轮廓增强 | +0.030 ns | +0.004 ns | 250 / 256 |
| Rain Princess | +0.006 ns | +0.026 ns | 252 / 256 |

厂商合并表：One Last Kiss 在 `0x000000`，Rain Princess 在 `0x0f0000`。
Rain 的完整固件 / 模型 payload 在 `0x600000`，378724 字节；OCR 启动器
只读 SPI，拷贝至 DDR `0x00800000` 并检查绑定的 FNV `a754791c`。
最终 Flash 有效长度 6670180 字节，小于板载 8 MiB。

原 Flash 已通过 JTAG bridge 完整回读 8388608 字节；器件识别为
Winbond W25Q64，JEDEC `EF6017`。备份位于本机忽略构建目录
`firmware/tinyml_style/build/style-switch-20261024/flash-before.hex`，其文件
SHA256 为 `e0d6980c80233a00a24f794156bdb0025eb0c8d8a0e50560a3be170116a11af9`。

位流、Flash 备份与输入 / 输出 tensor 留在上述构建目录，不提交大型生成文件。
该目录的 `manifest.json` 绑定模型、参数、固件、两套 FPGA 位流与合并 Flash。
最终文件 SHA256：`3017682dc0389f7b8604fd5c83e86b2be8565e960e3759e0d8613ad76eb3582b`。
板上已得到 `Flash verify successful`；工具首次验证失败后自动重写，第二次校验通过。

首次测试后用户报告 HDMI 卡帧与抖动。完整原 Flash 已回写并通过回读校验，
用户确认恢复正常。随后保留板上原控制固件：6364 字节、FNV `3709eec3`、
SHA256 `48d70e1c572711db7c135729c978a37fddd6a46ae19a4bf5788dd7faf91c189b`；
其 624 字节神经参数与当前参数表一致。该副本及来源 JSON 随构建源码保存。
保留固件是控制变量；尚未单独证明重编译导致了 HDMI 故障。

Rain Princess 的 SRAM 单独运行已通过相机输入 / 输出整帧 TFLite BUILTIN_REF
比对：49152 字节全部相等、最大误差 0 LSB，板上完整模型哈希也与原模型一致。
Sapphire SPI 采样修正后，板上 JEDEC 读值为正确的 `EF6017`。
这一步通过 JTAG 单独加载 ELF，不计作 Flash 自启动验收。

启动流程检查发现 JTAG 被动启动不满足内部重配置的主动模式要求，
因此删除了被动启动镜像的自动加载步骤。烧录后必须断电重上电，从 Flash
启动再测试 KEY3，依据厂商 [AN 010 v2.5](https://www.efinixinc.com/docs/an010-using-internal-reconfiguration-feature-v2.5.pdf)。
被动启动时的请求停留记录不计作一次成功切换。

随后板上重新启动，自动服务请求完成 8 次真实 Flash 重配置（4 个往返），
每次都核对目标镜像 ABI、显示完成帧和错误计数，均通过；初始重启来源
没有独立验证，用户也表示暂时不能断电，不能据此声称完成冷启动验收。
记录见 [自动往返](automatic-roundtrips.json)。

**本候选未通过 HDMI 验收。** 用户确认 Rain Princess 单独 SRAM 测试时
同一画面持续抖动；保留原控制固件的 One Last Kiss 在自动往返结束后也
不更新、持续抖动。两次短间隔 DDR 行采样的输入和输出都变化，但不能
代替显示器观测。[采样差异](physical-fault-buffer-diff.json) 保留了各行统计。
重新加载原 FPGA 镜像后曾两次收到正常确认；随后用户又报告彩条，
且在没有 JTAG 内存读取的重载对照中也不更新、有彩条。不能将此前确认
当作最终稳定验收。诊断版测得 HDMI 1920×1080、60 Hz，扩展 FIFO
错误为 0，但摄像头和 DDR 完整帧写入均为 0 fps；原因尚未确定。
用户随后取消切换任务，完整原 Flash 已回写、回读校验通过，并启动原版单风格 FPGA；
实屏恢复仍待用户确认，详见 [恢复记录](single-style-restoration.json) 和
[恢复烧录日志](restore-single-flash.log)。烧录脚本会拒绝重烧
已标记失败的双风格清单。

原 FPGA 镜像使用 Efinity `2026.1.132.5.14`，本机工具为
`2026.1.132.4.5`。这是尚待控制测试的构建差异，不是已证明的原因。
诊断镜像仅在 SRAM 临时运行，未写入 Flash；后续开发已按用户要求停止。
实体按键、冷启动和两种风格的 HDMI 合格结果均未取得。
当前验收状态保存在 [acceptance.json](acceptance.json)，随附
[Flash 回读日志](program-flash.log)、[SRAM 数值比对结果](rain-sram-reference-parity.json)
及 [视频回归日志](video-regression.log)。
