# 已验证 1080p60 Flash 固件

原生 1920×1080 RAW10，HTS=1622，VTS=1150；实测采集率 60.04383–60.04390 fps，CAM/DDR 完整帧 WR 均为 60–61，HDMI 为 60。用户确认实屏尺寸及画面正常。

全部 RTL 回归、Efinity map/interface/pnr/pgm 和 setup/hold 检查通过。此固件已写入 Winbond W25Q64 Flash 地址 0，并回读校验成功、配置复位启动及实际运行验证。SHA256SUMS 对应已烧录文件。

证据见 `docs/validation/20261003-1080p60/` 的 `final-validation.json`、`final-uart.log/.json` 和 `candidate-b-*`。20 秒实板抓取不替代长期运行测试。保留曝光与色彩校准按键；掉电后校准值需重新设置。
