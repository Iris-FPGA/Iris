# 恢复彩色显示版本

按用户要求撤回导致画面变粉的 CNN 色纹恢复及增强调整，保留此前从黑白恢复彩色的显示修复。

已从 `20261017-neural-colour/before/` 恢复源码、配套测试和调参文档；源码哈希与
`20261017-style-colour/source-manifest.json` 一致。默认相机颜色占 75%、CNN 占 25%，
饱和度 1.25 倍、每通道 32 级，`h` 轮廓阈值保留为 20。

`before/` 和 `before-rollback.bit/.hex` 保存回滚前的文件，历史验证目录保留供核对。
本次检查状态见 `rollback.json`，源码哈希见 `source-manifest.json`。

本次验证通过：三组单元回归共 30,720 个向量；`h→s` 完整分屏共 2,074,559 个样本；
离线预览与此前彩色修复版逐像素一致。仿真日志为 `tests.log`。
官方 Efinity map/interface/pnr/pgm 全部通过；最小 setup 余量 0.014 ns，
hold 余量 0.026 ns。构建日志为 `build.log`，相关报告保存在本目录。
位流为 `iris_ws/outflow/iris_ws.bit`，对应 `.hex` 也已重新生成。

本次未操作板卡，未写 Flash。
