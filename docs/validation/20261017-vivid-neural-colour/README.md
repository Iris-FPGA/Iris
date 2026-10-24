# 加强 CNN 彩色条纹

2026-10-17：用户反馈画面变粉，本方案已撤回，当前恢复同帧相机补色的彩色版本。
以下内容和验证结果仅记录历史方案，详见[回滚记录](../20261017-rollback-colour/README.md)。

针对“条纹不是太彩色”，将 `SATURATION_Q2` 默认值从 8 提高到 16，
即从 2 倍 RGB 色差提高到 4 倍。颜色仍来自原始 CNN，保留最亮通道，
加深其他通道；相机只提供轮廓亮度。用户的普通轮廓阈值 20 保持不变。
颜色过重时可降到 12（3 倍）或 8（2 倍）。

`colour-gain-options.png` 是同一份真实 CNN 快照的 2、3、4 倍色差对比，
三幅预览使用相同轮廓参数。4 倍版增强原有的粉红、红色条纹。
`cnn-gain-*.json` 保存参数和指标：该帧平均通道差从 2 倍版的 30.04
提高到 4 倍版的 60.08。

`default-camera-comparison.png`、`default-strokes-comparison.png` 使用当前 RTL
默认值生成，四栏依次为采集原图、原始 CNN、旧漂白显示、新版彩色显示。
它们是已有硬件快照的离线显示参考。两份共 614,400 个像素与独立卷积参考
逐像素一致，未出现最大/最小 RGB 通道差小于原始 CNN 的像素。
详见 `oracle-check.json` 和各图片对应的 JSON。

`tests.log` 记录三组参数的单元回归和 `h`→`s` 完整分屏检查。
三组单元共 30,720 个向量通过，完整分屏共 2,074,559 个样本通过。
`build.log` 及 `iris_ws.*` 报告记录 Efinity 构建和最终时序结果。
构建全部通过，setup 最小余量 +0.016 ns、hold +0.022 ns；
RAM10 256/256、DSP48 114/160。
`validation.json` 汇总结果、资源和位流哈希；`source-manifest.json` 记录源码哈希。
其他模式和 DDR 错误回退的完整回归见上一版
[保留 CNN 彩色条纹](../20261017-neural-colour/README.md)。

`before/` 和 `before-vivid.bit` 保留本次调整前的 2 倍版本。
当前位流输出为 `iris_ws/outflow/iris_ws.bit`，本次未加载到板卡，也未写 Flash。
参数说明见[风格彩色与调参](../../风格彩色与调参.md)。
