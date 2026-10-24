# Rain Princess TinyML 实板静态验证

2026-10-19。重新连接后识别到 FT4232H `0403:6011`，四个 UART 接口存在且可访问。
官方 JTAG 编程器读到 Ti60 ID `0x10660A79`，SRAM 加载成功；日志见
`program-sram.log`。随后使用官方 OpenOCD 加载配套 ELF 到 `0x00800000`。

完整新模型在 Ti60 上完成静态推理，硬件原始 INT8 结果与独立 TFLite BUILTIN_REF
完全一致：

| 项目 | 结果 |
|---|---|
| 模型 | Rain Princess INT8，128×128 RGB，125336 字节 |
| 硬件算子 | 16 Conv + 5 Add：STANDARD；2 NN2x：IRIS_RESIZE_HW |
| 严格硬件派发 | 全部 23 算子通过，无 CPU fallback |
| 输出长度 | 49152 字节 |
| 不同字节 / 最大误差 | 0 / 0 LSB |
| 输出 FNV-1a | `b334633c` |
| 输出 SHA256 | `818a4c3d7b1cd2850f4276b2dab594360fe971aae983b7b390910fc55b1e35e7` |
| Invoke | 4.40087053 秒，100MHz CLINT，排除逐层 UART 打印 |

证据：`board-static-debug.json`、`board-static-uart.log`、
`board-static-output.bin`、`board-static-run.log`、`openocd.log`。
模型、ELF 和位流 SHA256 绑定在报告中，最终状态见 `acceptance.json`。

这次通过的是一个确定性梯度/棋盘格输入。未验证摄像头输入、风格 HDMI 显示、
连续帧率或断电自启动。4.40 秒一次推理不满足实时视频要求，不能报告为实时模型已替换。
测试仅加载 SRAM，Flash 没有写入；板端停留在静态测试结束状态。

模型和 FPGA 的复现命令见[10-18 构建说明](../20261018-rain-princess-tinyml/README.md)。
