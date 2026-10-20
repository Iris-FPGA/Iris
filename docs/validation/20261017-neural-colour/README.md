# 保留 CNN 彩色条纹

2026-10-17：用户反馈画面变粉，本方案已撤回，当前恢复同帧相机补色的彩色版本。
以下内容和验证结果仅记录历史方案，详见[回滚记录](../20261017-rollback-colour/README.md)。

此目录记录 2 倍色差版本。当前默认已提高到 4 倍，新位流及验证见
[加强彩色条纹](../20261017-vivid-neural-colour/README.md)。

按用户确认的“原始 CNN 已有彩色条纹”修复显示后处理：

- 取消此前的相机 RGB 混色，颜色全部来自 CNN。
- 取消色阶量化，保留浅色细纹的差别。
- 取消抬白；以 CNN 最大通道为锚点增强色差，默认 2 倍。
- 轮廓和对比度的共同压暗量不超过最暗通道，防止彩色笔触被分别裁剪成全黑。
- 保留用户的 `h` 阈值 20，`n` 仍直接显示原始 CNN。

`cnn-camera-comparison.png` 和 `cnn-strokes-comparison.png` 是已有硬件快照的
离线参考。四栏依次为原图、原始 CNN、旧漂白轮廓、修复后的 CNN 彩色轮廓。
对应 JSON 保存原始输出哈希和每像素色差检查结果。
两份快照共 614,400 个像素均没有最大/最小通道差减小的情况，预览与独立参考逐像素一致。

`synthetic-cnn-stripes.png` 是专项测试图，输入颜色仅来自合成神经张量，
分别比较无轮廓、中等轮廓、强轮廓下的浅色细纹与暗彩笔触，不能作为实屏截图。

`unit-tests.log`、`panel-tests.log`、`build.log` 和 `validation.json` 记录检查结果。
`source-manifest.json` 记录源码 SHA256，三个 `iris_ws.*` 报告来自官方 Efinity。
`before/` 和 `before-neural-fix.bit` 保留修改前的相机混色候选供核对。

三组参数单元回归共 30,720 个向量通过；三组完整分屏共 6,223,677 个样本通过，
包含 `h→s`、`s→n`、DDR 读错误下的 `h→c`、银行切换与接缝对齐。

构建及最终时序通过；setup 最小 +0.023 ns、hold 最小 +0.026 ns，
RAM10 256/256、DSP48 114/160。位流为 `iris_ws/outflow/iris_ws.bit`，
SHA256 记录在 `validation.json`。

本轮未加载新位流到板卡，未写 Flash，实屏色纹与清晰度待确认。
参数说明见[风格彩色与调参](../../风格彩色与调参.md)。
