# Iris

基于 Efinix **Titanium Ti60F225I3**的实时风格化视频渲染系统工程。

- 工具链：Efinity `2026.1.132.4.5`
- 板卡：Ti60F225_DemoBoard_v4


## 目录结构

```
Iris/
├── iris_ws/          # Efinity 工程（top=top）
│   ├── iris_ws.xml        # 工程文件（源码清单 / peri / sdc 引用）
│   ├── iris_ws.peri.xml   # Interface Designer（引脚/电压/PLL/LVDS/MIPI）
│   ├── ip/csi_rx_59/      # efx_csi2_rx 5.9 生成物
│   └── src/               # RTL 源码（8x8 矩阵加速器、HDMI、MIPI、视频控制器等）
├── model_input/      # 固件模型输入目录（放置导出的模型权重、C 数组与加速头文件）
├── firmware/         # RISC-V 固件工程
│   └── tinyml_style/ # 8x8 硬件加速器 TinyML 固件源码
├── .script/          # 构建/烧录脚本
├── docs/             # 方案、板卡手册、纪要等
└── Ti60F225_DemoBoard_v4/   # 官方 Demo、驱动、原理图（gitignore）
```

## 快速开始

### 0. 前置

- Efinity `2026.1.132.4.5`
- Linux 环境

### 1. git clone

```bash
git clone https://github.com/FinResect/Iris.git
```

### 2. 环境配置

```bash
.script/setup-env
```

### 3. 编译

```bash
.script/build-iris
```

生成 `iris_ws/outflow/iris_ws.bit` 与 `iris_ws.hex`。

需要用 **KEY3 切换 One Last Kiss 轮廓增强版 / Rain Princess** 时，使用
[双镜像构建及烧录说明](firmware/style_switch/README.md)。两个原有风格各自保留，
切换会暂时中断 HDMI；普通 `build-iris` 仍构建单镜像。

### 4. 固件编译与一键烧录运行（8x8 矩阵加速架构）

在将模型放置于 `model_input/`（或在 `examples/fast_neural_style` 运行 `./train.sh` 自动导出）后：

```bash
# 1. 编译 RISC-V 固件（自动从 model_input 加载模型并链接 8x8 硬件加速器）
.script/build-firmware

# 2. 一键烧录位流至 SRAM 并由 OpenOCD 加载固件至 DDR3 启动
.script/sync-iris jtag
```
- **SRAM 极速模式（调试推荐）**：`.script/sync-iris jtag` 会先烧录 FPGA 逻辑，随后自动调用 OpenOCD 将编译好的固件载入片外 DDR3（`0x00800000`）并恢复 CPU 执行，同时监听 `/dev/ttyUSB2` 串口输出 30+ FPS 实时推理数据。
- **Flash 掉电保持模式**：`.script/sync-iris`（默认 `jtag_bridge`）经 JTAG 桥将逻辑固化至板载 SPI Flash，断电重上电自启动。

## 脚本一览（`.script/`）

| 脚本 | 作用 |
|---|---|
| `setup-env` | 一键环境配置：解析 `EFINITY_HOME` + 装 USB 规则 + 版本校验 |
| `setup-usb` | 安装 USB udev 规则并重载 |
| `80-efx-pgm.rules` | udev 规则文件（给 Efinix 下载器节点授权） |
| `build-iris` | 编译 FPGA 硬件位流 |
| `build-firmware` | 编译 RISC-V 固件：自动从 `model_input/` 读取模型并针对 8x8 矩阵加速架构构建 ELF |
| `build-style-switch` | 构建两种现有风格及独立启动固件，生成 KEY3 切换用 Flash 镜像 |
| `sync-style-switch` | 核对双镜像清单、时序及哈希后烧录 Flash 并回读校验 |
| `sync-iris` | 烧录：`jtag`（极速写 SRAM 并自动通过 OpenOCD 加载启动固件） / `jtag_bridge`（掉电保持烧 Flash） |
| `clean-iris` | 清理编译产物（`outflow/`、`work_*/`） |
| `efinity-env` | 共享 helper：解析 `EFINITY_HOME` 并 source `setup.sh` |

## 常见问题

- **烧录报 `Access denied (insufficient permissions)`**：USB 节点无写权限。运行 `.script/setup-usb`（或 `.script/setup-env`），然后拔插一次 USB。
- **`active` 模式报 `could not get flash device`**：`active` 是 SPI 直连，板载 USB 下载器不支持；用 `jtag_bridge`（flash）或 `jtag`（SRAM）。
- **`Unsupported JTAG Bridge version: 0.0`**：`jtag_bridge` 需先加载 JTAG Bridge 位流，`sync-iris` 已自动处理。
- **`setup.sh` 打印 `libstdc++` 警告**：仅为提示，不影响运行。
