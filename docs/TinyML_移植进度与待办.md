# TinyML 移植进度与待办

更新时间：2026-10-05（第二轮：硬件集成已实施并通过完整编译）。

目标：将 one_last_kiss INT8 风格迁移模型接入 Iris 的 Ti60F225I3 摄像头/DDR3/HDMI
系统，最终由 RISC-V 调度，FPGA 执行模型的逐元素和卷积计算。

当前状态：**RTL 集成完成，全链路编译（map/interface/pnr/时序/pgm）通过并生成
`iris_ws/outflow/iris_ws.bit` 与 `.hex`；仲裁器通过 iverilog 回归。**
仍**没有**：可运行的目标 ELF、烧板、上板数值一致性、实际帧率。
也就是说硬件骨架已落地，端到端推理与画面风格化尚未验证。

## 生成文件来源

后续统一使用官方 Generator 的输出：

```text
/home/fr/Program/FPGA/tinyml/tools/tinyml_generator/output/one_last_kiss_0_int8_core0/
  tinyml_core0_define.v
  one_last_kiss_0_int8_model_data.h
  one_last_kiss_0_int8_model_data.cc
```

Iris 副本（第二轮起布局有变化）：

- `iris_ws/src/cnn/tinyml_core0_define.generated.v` —— 生成器原件，逐字节保留
  （`cmp` 与 71753da 提交版本一致）。
- `iris_ws/src/cnn/tinyml_core0_define.v` —— **集成适配层**：include 生成器原件，
  并把官方 RTL 需要的 `TML_C0_RS_MODE` 映射到生成器输出的 `TML_C0_RESHAPE_MODE`
  （官方 RTL `tinyml_top/tinyml_accelerator/tinyml_accelerator_channels` 三处
  `include` 的都是 `tinyml_core0_define.v`，故适配层占据该文件名）。
- `iris_ws/RISC-V/one_last_kiss_0_int8_model_data.h/.cc` —— 不变。

不使用之前自写生成脚本产生的 `tinyml/one_last_kiss_0_generated` 作为集成来源。
模型为 125,336 字节，INT8 NHWC `[1,128,128,3]` 输入输出，含 16 个 Conv2D、5 个 Add、
2 个 ResizeNearestNeighbor。模型报告位于 `one_last_kiss_style/`。
模型已通过的软件检查不代表 TinyML 板端数值一致性已验证。

官方 RTL 源固定为 **Iris-FPGA/tinyml（Efinix-Inc/tinyml fork）@ `96886fa0`**，
已 clone 到 `../tinyml`（固件 Makefile 的 `TINYML_ROOT` 默认值）。

## 已落地内容

| 内容 | 路径/状态 |
|---|---|
| 现有视频系统 | `iris_ws/src/top.v`；已有摄像头、DDR3 帧缓存和 HDMI |
| Sapphire SoC IP（efx_soc 3.4.1） | `iris_ws/ip/SapphireSoc/`（无头生成）+ `iris_ws/embedded_sw/SapphireSoc/`（BSP） |
| 无头 IP 生成脚本 | `.script/gen-sapphire-soc(.py)`（需要 Java 17，自动回退 `~/Applications/jre17`） |
| 官方 TinyML RTL 副本 | `iris_ws/src/cnn/rtl/`（tinyml 4 文件 + common/ + axi/ + hw_accel/，均来自官方 source.f 全集） |
| SoC+加速器子系统 | `iris_ws/src/cnn/tinyml_subsystem.v` |
| DDR 三主仲裁器 | `iris_ws/src/ddr/axi_ddr_arbiter.v` |
| 仲裁器回归测试 | `tests/video/tb_axi_ddr_arbiter.sv`（挂入 `tests/video/run_video_tests.py`，PASS） |
| 静态模型固件骨架 | `firmware/tinyml_style/` |
| 固件构建入口 | `.script/build-tinyml-firmware` |
| 固件详细接口说明 | `firmware/tinyml_style/README.md` |

固件骨架复用外部 TinyML 仓库的 TFLite Micro、平台驱动及 `tinyml_lib.a`，固定参考版本
为 `96886fa0c73e25e6218db7d0863f84677cf65138`，没有批量复制第三方源码。
已经包含模型注册、确定性静态输入、加速器配置探测、逐层 profiler、arena 用量及输出校验和。
链接地址必须显式提供，不默认占用现有视频内存。

目前的固件**仍使用软件最近邻上采样**，官方 Conv/Add 内核也可能回退到软件。
因此 `STRICT_DISPATCH=1` 刻意拒绝构建；后续不能仅移除检查就宣称 CPU 只负责调度。

已完成的验证范围：host 模型格式/算子约定检查、固件入口的 host 语法检查、构建脚本语法及
严格模式/缺失依赖报错检查、**仲裁器 iverilog 回归**、**Efinity 全链路编译**。
host 语法检查不是 RISC-V 目标编译；输出校验和尚无黄金参考值。

## 关键集成决策（第二轮新增，均为可回退的单点修改）

1. **单时钟域**：SoC system/peripheral/memory 全部接 `core_clk`（100 MHz）。
   `settings.json` 的 `Frequency` 由 300 改 100 后重新生成，BSP `SYSTEM_CLINT_HZ=100000000`
   与实际时钟一致。省一个 PLL；性能不足时再加 300 MHz PLL（§7）。
2. **复位门控**：`tinyml_rst_n = core_pll_locked & ddr_pll_locked & ddr_cal_done`；
   仲裁器复位 = `video_rst_n & tinyml_rst_n`。CPU/加速器在 DDR 校准完成前不可访问内存。
3. **UART 引脚共享**：物理 TX 由 `key_i[3]` 实时选择——松开 KEY3 = 原 Iris 标定串口
   （27 MHz `uart_rx_tx`/`ae_uart_log`，既有标定工作流不变），按住 KEY3 = Sapphire CPU
   控制台（100 MHz UART0）。RX 同时送给两个 UART。SoC UART 的 RX 进子系统后经 2FF 同步。
   peri 里 rxd/txd 的 IO 寄存器（27 MHz 域）保留——两个源都经其采样，115200 波特率下
   27 MHz 量化（±37 ns）无影响。
4. **JTAG_USER1**：`iris_ws.peri.xml` 的空 `<efxpt:jtag_info/>` 替换为官方块，
   `top` 增加 8 个 `jtag_inst1_*` 端口，接 SoC `jtagCtrl_*`（OpenOCD/CPU 调试加载入口）。
5. **模块 `reset` 冲突**：官方 `common_reset_ctrl.v` 也定义了 `reset`（与
   `src/hdmi/reset.v` 接口完全相同），后者从工程清单移除（文件保留在磁盘），由官方 common 版
   服务 `mipi_rx` 的实例化。
6. **加密 IP 依赖全集**：加密的 `tinyml_accelerator.v` 内部例化了官方 `source.f` 里的
   common/axi/hw_accel 模块（名字不可见，靠补齐官方文件集消除
   `instantiating unknown module`），因此官方 interconnect（即使本设计未用它做仲裁）
   也必须在编译单元内。
7. **不使用官方 `axi_interconnect_beta` 做仲裁**：官方互连全部加密，无法按本文件 §3
   要求逐项确认其 ID/背压/错误响应假设，且开源仿真器无法验证加密网表。
   自写 `axi_ddr_arbiter.v`（明文、iverilog 可测），官方互连保留在
   `src/cnn/rtl/axi/` 仅作编译依赖与参考。

## 待办顺序

### 1. 工具链与 Sapphire SoC —— 基本完成

- [x] 配置实际 Efinity 路径：`path/efinity_home = /home/noir/Applications/efinity/2026.1`
  （本机安装可用；注意该文件只能在 bash 下 source `.script/efinity-env`，zsh 直接 source
  会因 `read -rp` 语法差异把文件清空——已恢复）。
- [x] 生成单核 Sapphire SoC IP：`.script/gen-sapphire-soc`（无 GUI；efx_soc 3.4.0→3.4.1
  版本重绑定在脚本内完成；生成物含 `SapphireSoc.v` 与 RAM 初始化 bin）。
- [x] 生成对应 embedded_sw/BSP：`iris_ws/embedded_sw/SapphireSoc/`
  （`bsp/efinix/EfxSapphireSoc/include/{soc.mk,soc.h,bsp.h}`、`software/standalone/common/`
  含 `bsp.mk`、`riscv64-unknown-elf.mk`、`start.S`、`trap.S`、`syscalls.c`、openocd cfg）。
- [x] RV32IM + Zicsr、`ilp32` 软浮点（`soc.mk`：`RV_M=yes` 其余 no），与 `tinyml_lib.a` 一致；
  自定义指令、DDR 128-bit 半双工口、UART0、CLINT、PLIC、DEBUG(JTAG_USER1) 均开。
- [x] IP 生成需要 Java 17（`EfxSapphireSoc.jar` 含 class major 61）：本机装了便携
  Temurin 17 到 `~/Applications/jre17`，`gen-sapphire-soc` 自动加 PATH。
- [ ] **交叉编译器**：`riscv-none-elf-*` 仍未安装（`riscv64-unknown-elf.mk` 默认前缀
  `riscv-none-elf-`，可用 xPack riscv-none-elf-gcc 满足）——§4 的前置。
- [ ] 启动方式确认：首版按调试器加载（JTAG_USER1 已接好）；flash 启动/bootloader
  （`ref_files/bootloader_16MB/SapphireSoc/bootloader.hex`，官方 16MB HyperRAM 工程产物）
  在 Iris 上的行为未验证。

验收现状：IP+BSP 完整、版本一致；**最小串口程序交叉编译与上板执行未做**（缺工具链）。

### 2. 官方 TinyML RTL 接入 —— RTL 完成，能力查询待上板

- [x] 官方 RTL 来源选定：`../tinyml @ 96886fa0`，文件集 = 官方 `source.f` 全集，
  复制到 `iris_ws/src/cnn/rtl/`（保留许可头，未修改官方文件内容）。
- [x] 使用官方 output 的 Core 0 配置：AXI128、Standard Conv 4/2、Standard Add、Cache512
  （生成器原件未改动）。
- [x] 版本差异处理：`TML_C0_RESHAPE_MODE` → `TML_C0_RS_MODE` 在适配层映射（见上文布局）。
- [x] 接通 Sapphire 自定义指令 cmd/rsp、背压、完成中断（`cmd_int`→`userInterruptA`=6）、
  时钟复位（`tinyml_subsystem.v`；APB slave0/1 暂时 tie-off，DMA 未例化，
  `userInterruptB`=0）。
- [x] 加速器/CPU 内存访问等 DDR 校准完成后释放（`tinyml_rst_n`）。
- [x] 更新 Efinity 源文件清单（`iris_ws.xml`：design_file×30+、SapphireSoc ip 条目、
  include 路径 `src/cnn`、`src/cnn/rtl`、`ip/SapphireSoc`），sv_09 按文件指定。
- [ ] 验收剩余项：RTL 已在 Efinity 中解析/展开并综合通过（map PASS）；**加速器能力查询
  读回与配置一致**需要 ELF + 上板（§4）。

### 3. DDR 共享与地址规划 —— 仲裁器完成并仿真通过，共享内存待上板

- [x] **自写三主仲裁 `iris_ws/src/ddr/axi_ddr_arbiter.v`**（替代不可审的官方互连）：
  - 读、写方向各自独立授权、**每方向同时只有一个下游事务**（B/RLAST 归来才换主），
    响应按授权归属路由，不依赖 AXI ID（各主 ID 可冲突，仅回传给控制器回显）；
  - 每方向轮询（round-robin），显示读路径最坏等两个他人 burst；
  - 地址范围检查：`addr[31:28] != 0` 本地 SLVERR（写方向吞掉全部 W beat 后回
    SLVERR+正确 BID；读方向本地产生 `arlen+1` 拍 SLVERR+RLAST），**不会**截断别名进视频区；
  - 写数据在该 burst 地址握手之后才放行（AXI 允许 slave 等 AWVALID 再收 W），
    这是范围检查先于任何 DDR beat 的前提，也覆盖 W-before-AW；
  - 下游单地址口由既有 `axi_atype_bridge` 复用（其头注释证明控制器支持读写重叠）。
- [x] `tests/video/tb_axi_ddr_arbiter.sv`（iverilog，挂入 `run_video_tests.py`）：
  三主并发+随机背压、载荷/ID/RESP/RLAST 校验、下游未决 ≤1、响应 one-hot、地址稳定、
  越界 SLVERR 不进下游、W-before-AW、65 aw/65 ar 全通过。
  期间修过一个 **TB 自身**的竞态（随机延迟恰好落边沿导致假握手，negedge 驱动修正），
  DUT 未发现缺陷。
- [x] `top.v` 接线：frame_buffer(S0) + CPU(S1) + 加速器(S2) → 仲裁 → `axi_atype_bridge`
  (IDW 4→8) → `efx_ddr3_axi`（WID 用仲裁捕获的 `mem_wid`）。
- [ ] 共享内存仿真通过+CPU/加速器看到同一物理数据：需 §4 ELF 后上板。
- [x] 地址划分（写入固件链接与后续软件约定）：视频 `[0,0x5F4000)`，
  **推理窗口 `DDR_BASE=0x00800000`（8 MiB 对齐起）**，边界不超过 `0x10000000`；
  这是本次落实的方案。
- [ ] CPU cache 与 TinyML cache 的 clean/invalidate、fence 规则：随 §4 驱动落实。
- [ ] 并发主设备的专项仿真已由 TB 覆盖（随机背压/越界/复位场景复位项待补：TB 目前
  只在启动复位）。

### 4. 固件目标构建与静态推理 —— 未开始（缺交叉编译器）

- [ ] 安装 `riscv-none-elf-` 工具链（建议 xPack 发行包解压到 `~/Applications`）。
- [ ] 用实际生成的 BSP 填 `STANDALONE`/`BSP_PATH`：STANDALONE =
  `iris_ws/embedded_sw/SapphireSoc/software/standalone`，BSP_PATH =
  `iris_ws/embedded_sw/SapphireSoc/bsp/efinix/EfxSapphireSoc`。
  **注意**：生成树里是 `common/syscalls.c`（非 README 假设的 `syscalls.s`），
  Makefile 的 SRCS 与 `$(STANDALONE)/include` 需按生成树微调（生成树没有 `include/`）。
- [ ] `DDR_BASE=0x00800000`、`DDR_BYTES`（建议 0x00800000）编译链接，核对 map。
- [ ] 上板：UART（按住 KEY3）、JTAG_USER1 加载、加速器能力查询、逐层 profiler。
- [ ] host 黄金输出逐元素比对；纯软件 vs 硬件 Conv/Add 分别验证。

### 5. 硬件最近邻上采样与严格调度模式 —— 未开始

- [ ] `tinyml_top.v` 官方已留 function ID bit9=1 的用户扩展位（注释行），在其上实现
  0x200..0x206 提案接口（见 `firmware/tinyml_style/README.md`），RTL + 驱动同步落地。
- [ ] INT8 NHWC 2x 上采样（[1,32,32,32]→[1,64,64,32]、[1,64,64,16]→[1,128,128,16]）。
- [ ] TFLM Resize 注册、禁回退，黄金数据测试后才放开 `STRICT_DISPATCH=1`。

### 6. 摄像头输入与显示输出 —— 未开始

- [ ] 去 Bayer 后 RGB 取 128×128 快照 → int8 量化写入 `0x00800000` 输入张量区。
- [ ] 推理输出反量化 → 缓冲 → 显示路径；重复显示已完成帧，HDMI 不等推理。
- [ ] 撕裂/所有权保护（现有三缓冲只保护显示读）。

### 7. 整机资源、时序与性能 —— 首轮数据已记录

- [x] 首次完整编译（2026-10-05，Efinity 2026.1.132.4.5）：
  - map 估算：FF 27,102 / LUT4 33,489 / ADD 6,595 / DSP48 37 / **RAM10 241**；
  - PNR 实际：**XLR 54,922/60,800（90%）、mem 241/256（94%）、dsp 37/160**；
  - 时序：setup 最差 **+0.011 ns**（core_clk→ddr_twd_clk），hold 最差 **+0.026 ns**
    —— 收敛但极紧，是 §7 的首要优化对象；
  - 产物 `iris_ws/outflow/iris_ws.bit/.hex`（**未烧板**）。
- [ ] 资源再平衡（RAM 94%/XLR 90% 无余量，后续加 DMA/上采样/显示缓冲会超）。
- [ ] 逐层推理时间、DDR 带宽、整帧延迟测量（需 §4/§6）。
- [ ] 不得通过静默 CPU 回退规避资源不足；记录模型哈希/工具版本/复现命令。

## 下一次继续的入口

```bash
# 仲裁器回归（已通过）
python3 tests/video/run_video_tests.py

# 全链路编译（已通过，~5 分钟）
.script/build-iris

# 固件（缺 riscv-none-elf 工具链，先装再跑）
.script/build-tinyml-firmware check-model
```

下一步优先级：§4 工具链+ELF+上板能力查询 → §6 输入输出通路 → §5 上采样去软件回退。
不要把“编译通过”当成“集成成功”；上板数值一致性和帧率仍是最终验收。
