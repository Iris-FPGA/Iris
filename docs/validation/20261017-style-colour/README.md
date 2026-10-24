# 同帧彩色风格显示

2026-10-17：用户反馈后续 CNN 色纹增强使画面变粉，已恢复本目录对应的彩色显示方案。
当前源码保留同帧相机补色，撤回 CNN 独占颜色和 2/4 倍色差增强。
本目录保留首次构建的结果；本次回滚的检查与位流记录见
[回滚记录](../20261017-rollback-colour/README.md)。

本目录记录右侧近似黑白的修复。新版在显示端混合配对相机 RGB 与 CNN RGB，
增强饱和度、压缩色阶，再叠加原有 5×5 平滑主轮廓。

- `colour-comparison.png`：采集输入 / 原始 CNN / 修改前轮廓 / 新版默认轮廓。
- `colour-blocks.png`：同样四栏，新版改用饱和度 1.5 倍、每通道 16 级、阈值 32。
- 对应 JSON 记录参数和原始神经输出 SHA256。
- `build.log`、`iris_ws.map.rpt`、`iris_ws.res.csv`、`iris_ws.timing.rpt`：官方 Efinity 构建证据。
- `source-manifest.json`：相关源码 SHA256。
- `validation.json`：测试、构建和硬件操作状态，以此文件为验证结果记录。
- `before-colour-fix.bit`：开始构建前保存的原位流。

预览来自既有 `20261016-camera-median/diagnostic` 硬件快照，是离线显示参考，
不是新版本 HDMI 截图。新位流已通过构建、资源和最终时序检查：
RAM10 256/256、DSP48 114/160，setup 最小 +0.014 ns、hold 最小 +0.026 ns。
新位流路径为 `iris_ws/outflow/iris_ws.bit`，SHA256 为
`a257e499230d092d5c7a9e572d29422e6c3783086b76615391db9231d60231cd`。

RTL 回归已通过：三种参数配置共 30,720 个单元向量；三组完整分屏共
6,223,677 个检查样本，包含 `h→s`、`s→n`、DDR 读错误下的 `h→c`、
银行切换、逐像素颜色和左右接缝对齐。单元向量特别检查灰白 CNN 配彩色相机。

本轮未加载新位流到板卡，未写 Flash；新实屏的颜色、噪声和画风尚未验收。
完整参数说明见[风格彩色与调参](../../风格彩色与调参.md)。
