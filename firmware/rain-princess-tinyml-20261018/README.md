# Rain Princess TinyML 静态测试产物

2026-10-19 Ti60 实板验证通过：完整 23 算子使用硬件执行，49152 字节输出与
TFLite BUILTIN_REF 完全相等。单次 Invoke 4.40087053 秒，排除逐层 UART 打印。
这是一个固定输入的验证，尚未达到实时视频要求。

`iris_ws.bit` 仅含 FPGA 配置；SRAM 加载后需用 OpenOCD 加载
`tinyml_style.elf` 并从 `0x00800000` 运行。预期结果为 `static-golden.bin`。
此版本不显示新风格 HDMI 图像。

[实板结果](../../docs/validation/20261019-rain-princess-tinyml/README.md) ·
[构建及上板说明](../../docs/validation/20261018-rain-princess-tinyml/README.md)
