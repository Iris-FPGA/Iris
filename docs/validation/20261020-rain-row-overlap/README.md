# Complete Rain Princess at 30 FPS

The right HDMI panel produces **30.0505 new complete AI frames/s** on Ti60.
The 180-frame board run has a median Invoke of **31.77482 ms**, while fresh
display commits are separated by **33.27731 ms**. Underflow, read errors and
rejected commands are all zero. The displayed 49,152-byte RGB tensor matches
the original model's TFLite BUILTIN_REF output byte for byte, with zero LSB
error. This is new inference output, measured after VS acknowledgement;
neither the HDMI refresh count nor UART reception time is used as AI FPS.

The previous complete-model vendor implementation delivered 2.7178 FPS, so
the end-to-end increase is approximately **11.06x**. Its median Invoke was
354.545 ms. The intermediate row-cached version delivered 20.0337 FPS; Add,
Resize and row-output optimizations were needed to fit the next HDMI commit.

The model is unchanged:

- `one_last_kiss_style/models/rain-princess-cropped_style_int8.tflite`
- SHA256 `26852af8672516371f19b05e0dcd06ba6c533c13d9cc78fcf2b65b3f838729c5`
- Complete 16 Conv + 5 Add + 2 Resize network; native 128x128 RGB INT8.
- Original quantization, trained weights, residual connections and RGB order.
- HDMI remains 1920x1080, with two 960x1080 panels.

## Backend changes

Commit `f94b123` (`backend optimization done`) provided the useful pattern:
on-chip data reuse, overlapped camera/inference/display, three independent
bank leases and nonblocking UART. Its earlier three-layer student network
does not establish Rain Princess throughput. This implementation applies
those patterns to all operators of the original network.

- `iris_rain_conv.v`: 64 pipelined INT8 products per clock, four input row
  banks, layer-local packed weight RAM and exact per-channel requantization.
  Input rows and weights are reused on chip instead of reread per window.
- `iris_rain_backend.v`: bounded AXI bursts, page splitting, complete operator
  configuration checks, error/abort draining, and two output banks in the
  existing row RAM. One row computes while the preceding row drains to DDR.
  Rows wider than 2 KiB use the serial path.
- `iris_rain_add.v`: four parallel lanes preserve gemmlowp double rounding
  and full intermediate width. All five residual Add tensors are checked.
- Resize uses eight-beat staging in this backend. The default two-beat mode
  and generic C4/C8 modes remain covered by video regression.
- Firmware binds only the graph input and final output to the leased camera
  and display banks. All intermediate tensors keep TFLM's arena allocation.
  This removes two complete-frame copies and retains per-operator CPU cache
  maintenance. Capture of the next bank overlaps inference.
- Custom CI `0x260..0x267` owns Conv/Add exclusively. CPU pixel fallback is
  rejected. The custom firmware excludes the vendor encrypted accelerator
  driver constructor; the trained FlatBuffer remains in the ELF unchanged.

## Verification and artifacts

`live-debug.json` and `live-uart.log` contain the 180-frame board measurement.
`reference-parity.json` records exact equality of the displayed input/output
pair to the unchanged reference model. `acceptance.json` records artifact
hashes and final performance. `soak-report.json` records the subsequent
continuous run without reloading the CPU; `soak-reference-parity.json` checks
another displayed pair after that run. The CPU is resumed after each dump. The final soak reached 30.0477 FPS over 3,600 consecutive frames and its displayed pair also passed exact parity.
`soak-initial-*` retains an earlier capture with old UART records in its
prefix; its sequence check failed. The final soak requires a full window of
3,600 consecutive frame sequence numbers and does not use that prefix.

`rtl-results.json` contains all 16 Conv and five Add DMA tests. Every Conv
runs twice consecutively; the final test also checks invalid configurations,
overlap/range rejection, R/B errors, and abort draining. `backpressure.log`
holds a bank write for 12,000 clocks, verifies ownership is retained, and
checks the complete output after both buffered rows resume. Core arithmetic
regression is recorded in `../20261020-rain-row-backend-restart/rtl-results.json`.
`resize8-rgb.log` and `resize8-generic.log` in the preceding Add candidate
directory cover Resize/Copy data, page boundaries, read-only export and faults.

Efinity 2026.1, Ti60F225, I3 timing model, 100 MHz core:

| Resource / timing | Result |
| --- | ---: |
| XLR | 55,169 / 60,800 |
| RAM | 252 / 256 |
| DSP | 143 / 160 |
| Minimum setup slack | +0.013 ns |
| Minimum hold slack | +0.026 ns |

See `build.log`, `iris_ws.place.rpt` and `timing-summary.txt`. This result
uses the same board and clock constraints as the baseline. Only **SRAM** was
programmed. There is no Flash boot image change; power loss requires loading
the bitstream and ELF again.

## Reproduce

Generate packed weights from the untouched model using the Python environment
containing numpy, tflite, flatbuffers and tflite-runtime:

```sh
.venv-tinyml/bin/python .script/compile-rain-backend.py \
  one_last_kiss_style/models/rain-princess-cropped_style_int8.tflite \
  firmware/tinyml_style/build/rain_row_backend

python3 .script/prepare-tinyml-project.py --live-rgb --burst-dma --rain-backend \
  --parameters iris_ws/RISC-V/rain_princess_8x2_lite_cache1024 \
  --output firmware/tinyml_style/build/rain_row_overlap/iris_ws
IRIS_PROJ_DIR="$PWD/firmware/tinyml_style/build/rain_row_overlap/iris_ws" .script/build-iris

.script/build-tinyml-firmware MODEL_PROFILE=rain_princess LIVE_DEMO=1 \
  LIVE_PIPELINE=1 RAIN_BACKEND=1 OBJDIR=build/rain_row_direct_live \
  STANDALONE="$PWD/iris_ws/embedded_sw/SapphireSoc/software/standalone" \
  BSP_PATH="$PWD/iris_ws/embedded_sw/SapphireSoc/bsp/efinix/EfxSapphireSoc" \
  RISCV_BIN=/mnt/mydata/Iris/dev/toolchains/xpack-riscv-none-elf-gcc-12.3.0-2/bin/riscv-none-elf- \
  DDR_BASE=0x00800000 DDR_BYTES=0x02000000 STRICT_DISPATCH=1 -j8
```

Use a new project directory if one already exists. The generated vendor
parameter directory supplies model identity; this optional backend replaces
its Conv/Add engines and uses the actual 8x8 parallelism in the project manifest.

After stopping OpenOCD to release JTAG, program SRAM only:

```sh
IRIS_PROJ_DIR="$PWD/firmware/tinyml_style/build/rain_row_overlap/iris_ws" .script/sync-iris jtag
```

Restart OpenOCD with `.script/openocd_ftdi_iris.cfg` and the SapphireSoc BSP
`openocd/debug_ti.cfg`, then run:

```sh
python3 .script/run-tinyml-live \
  --elf firmware/tinyml_style/build/rain_row_direct_live/tinyml_style.elf \
  --bit-file firmware/tinyml_style/build/rain_row_overlap/iris_ws/outflow/iris_ws.bit \
  --riscv-prefix /mnt/mydata/Iris/dev/toolchains/xpack-riscv-none-elf-gcc-12.3.0-2/bin/riscv-none-elf- \
  --expected-model one_last_kiss_style/models/rain-princess-cropped_style_int8.tflite \
  --frames 180 --timeout 90 --output /tmp/rain-live
.venv-tinyml/bin/python .script/check-tinyml-camera.py \
  --model one_last_kiss_style/models/rain-princess-cropped_style_int8.tflite \
  --input /tmp/rain-live-input.bin --actual /tmp/rain-live-output.bin \
  --output /tmp/rain-reference
```

Compute fresh FPS as `100000000 / mean(hardware_frame_period_ticks[5:])`.
The initial profile UART dump is excluded; it deliberately blocks one early
frame while printing and is outside sustained throughput. Output parity must
pass before accepting an FPS result.
