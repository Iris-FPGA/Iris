# Rain Princess：完整模型 TinyML 静态推理

2026-10-19 更新：已连接 Ti60 并通过完整 23 算子静态硬件推理验证，49152 字节
输出与参考完全一致。Invoke 4.40087053 秒，不含逐层 UART 打印。
详见[实板验证结果](../20261019-rain-princess-tinyml/README.md)。以下保留 10-18 的离线构建记录。

2026-10-18。本次保留新模型的完整网络，以官方 TinyML 运行库和加速器尝试部署。
模型转换、主机契约检查、RISC-V 固件构建及 FPGA 全流程构建通过。
尚未进行板端推理：本机未发现 Ti60 板载 FT4232H（0403:6011）或对应 UART。
这是 128×128 静态输入测试，不是摄像头实时换风格或性能验收。

## 模型和配置

- 来源：`one_last_kiss_style/models/rain-princess-cropped_style_int8.tflite`。
- SHA256：`26852af8672516371f19b05e0dcd06ba6c533c13d9cc78fcf2b65b3f838729c5`。
- 125336 字节；INT8 NHWC `[1,128,128,3]`；16 Conv、5 Add、2 NN2x。
- 输入 scale=1、zero point=-128；输出 scale=2.283437490463257、zero point=-89。
- 官方 TinyML 固定 revision `96886fa0c73e25e6218db7d0863f84677cf65138`。
- 官方生成器 Conv4×2、AXI128、cache ENABLE；Conv/Add 使用 STANDARD，
  NN2x 使用 Iris 硬件。严格派发拒绝 CPU fallback。
- `iris_ws/RISC-V/rain_princess/` 保存生成器的模型 C 数组、配置和清单。
  输入仅为取得合法 C 标识符暂存为 `rain_princess_int8.tflite`，字节没有改变。

## 已完成的检查

1. 官方生成器成功分析模型，并生成全部参数；C 数组还原后与原 TFLite 逐字节一致。
2. `rain_princess`、`original`、`rgba640` 三个固件配置的主机模型契约检查均通过。
3. xPack RISC-V GCC 12.3.0-2 编译严格硬件固件成功，ELF 入口 `0x00800000`。
   DDR 静态分配/保留合计 4476736 字节，控制数据 1328 字节，栈预留 8 KiB。
   链接器对裸机 ELF 提示 RWX LOAD segment；没有 Linux 进程页权限语义。
4. Efinity map/interface/pnr/pgm 全部通过，最小 setup +0.016ns、hold +0.019ns；
   57510/60800 XLR、253/256 RAM、39/160 DSP。详见 `fpga-build.log`。
5. TFLite BUILTIN_REF 静态参考输出 49152 字节，FNV-1a `b334633c`，SHA256
   `818a4c3d7b1cd2850f4276b2dab594360fe971aae983b7b390910fc55b1e35e7`。
   本机采用 tflite-runtime 2.14.0；同一运行时生成的原 One Last Kiss 固定输入输出
   与历史 TF2.20/实板验证 SHA256 完全一致。该交叉检查不能代替新模型上板比较。

## 本机产物

- 固件：`firmware/tinyml_style/build/rain_princess/tinyml_style.elf`。
- 独立 FPGA 工程：`firmware/tinyml_style/build/rain_princess/iris_ws/`。
- 位流：上述工程的 `outflow/iris_ws.bit`、`outflow/iris_ws.hex`。
- 静态输入/参考：本目录 `static-input.bin`、`static-golden.bin`。
- 固定打包产物：`firmware/rain-princess-tinyml-20261018/`，附 SHA256 和状态清单。

产物目录的 `manifest.json` 已更新为 10-19 实板结果；本目录 `acceptance.json`
保留 10-18 离线状态，最新验收在相邻 `20261019-rain-princess-tinyml/acceptance.json`。

独立工程关闭 `ENABLE_STREAM_CNN/ENABLE_STYLE_DEMO/ENABLE_STYLE_VISIBILITY/
ENABLE_STYLE_CONTOUR`，启用官方 TinyML。OCR 复位代码为 `JAL x0,0`，
等待 OpenOCD 加载 DDR ELF；视频端保留相机画面，不显示新风格推理输出。
FPGA 位流自身不包含新模型固件，必须同时加载配套 ELF。

## 复现构建

以下命令从 `dev/fastnst` 执行。官方 TinyML 位于相邻 `../tinyml`，RISC-V 编译器
位于 `../toolchains/xpack-riscv-none-elf-gcc-12.3.0-2/bin/`。`EFINITY_HOME`
应指向本机安装根目录；生成器使用其自带 Python/PyQt6。

```bash
export RISCV_PREFIX="$PWD/../toolchains/xpack-riscv-none-elf-gcc-12.3.0-2/bin/riscv-none-elf-"

# 已生成的 C 数组和配置可直接使用。
.script/build-tinyml-firmware check-model MODEL_PROFILE=rain_princess
.script/build-tinyml-firmware MODEL_PROFILE=rain_princess \
  STANDALONE="$PWD/iris_ws/embedded_sw/SapphireSoc/software/standalone" \
  BSP_PATH="$PWD/iris_ws/embedded_sw/SapphireSoc/bsp/efinix/EfxSapphireSoc" \
  RISCV_BIN="$RISCV_PREFIX" DDR_BASE=0x00800000 DDR_BYTES=0x02000000 \
  STRICT_DISPATCH=1 -j8

# --output 必须是尚不存在的新目录。本机首次生成的目录已包含通过构建的工程。
python3 .script/prepare-tinyml-project.py \
  --parameters iris_ws/RISC-V/rain_princess \
  --output firmware/tinyml_style/build/rain_princess/rebuilt-iris_ws
IRIS_PROJ_DIR="$PWD/firmware/tinyml_style/build/rain_princess/rebuilt-iris_ws" \
  .script/build-iris
```

重新生成官方模型文件时，先将原文件复制为合法的 C 标识符文件名，使用：

```bash
mkdir -p firmware/tinyml_style/build/rain_princess
cp one_last_kiss_style/models/rain-princess-cropped_style_int8.tflite \
  firmware/tinyml_style/build/rain_princess/rain_princess_int8.tflite
# 在已 source "$EFINITY_HOME/bin/setup.sh" 的 shell 中执行。
"$EFINITY_HOME/bin/python3" .script/gen-tinyml-model.py \
  firmware/tinyml_style/build/rain_princess/rain_princess_int8.tflite \
  iris_ws/RISC-V/rain_princess --in-parallel 4 --out-parallel 2
```

参考环境使用 Python3.11，安装 `numpy==1.26.4 tflite-runtime==2.14.0`：

```bash
.venv-tinyml/bin/python .script/make-tinyml-reference.py \
  --model one_last_kiss_style/models/rain-princess-cropped_style_int8.tflite \
  --output docs/validation/20261018-rain-princess-tinyml/static
```

## 连接 Ti60 后的验证

先连接板卡电源、FPGA 下载 USB 和 UART，确认 FT4232H 及串口。仅加载测试位流到 SRAM：

```bash
IRIS_PROJ_DIR="$PWD/firmware/tinyml_style/build/rain_princess/iris_ws" \
  .script/sync-iris jtag
```

用支持 RISC-V bscan tunnel 的官方 OpenOCD 启动调试服务（Tcl 端口 6666）：

```bash
openocd -f .script/openocd_ftdi_iris.cfg \
  -f iris_ws/embedded_sw/SapphireSoc/bsp/efinix/EfxSapphireSoc/openocd/debug_ti.cfg
```

另一个终端加载新模型 ELF，导出结果并与软件参考比较；按实际设备修改 `--uart`：

```bash
.script/run-tinyml-bringup \
  --riscv-prefix "$RISCV_PREFIX" --uart /dev/ttyUSB2 --timeout 180 \
  --elf firmware/tinyml_style/build/rain_princess/tinyml_style.elf \
  --bit-file firmware/tinyml_style/build/rain_princess/iris_ws/outflow/iris_ws.bit \
  --golden docs/validation/20261018-rain-princess-tinyml/static-golden.bin \
  --output docs/validation/20261018-rain-princess-tinyml/board-static
```

上板验收需要同时检查：Invoke 完成、23 个节点全为硬件模式、49152 字节结果完全相等，
再记录排除 UART 打印后的 Invoke 耗时。单次静态推理不能证明连续帧率。
新输出零点为 -89，未来接 HDMI 时还须修改输出反量化、缩放与图像布局；
不能沿用当前三层 RGBA640 显示端的固定零点和 Q24 比例。
