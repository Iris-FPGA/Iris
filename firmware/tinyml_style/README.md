# Iris TinyML Style Firmware

Static-input bring-up for the official Ti60 TFLM runtime. The strict build now
contains a real Iris INT8 nearest-neighbor 2x DMA accelerator. Conv/Add dispatch
must return `OP_OK` with `STANDARD` or `LITE`; unsupported hardware dispatch
stops before the vendor CPU fallback loops. The original model has completed all 23 hardware operations on board with exact
49152-byte equality to TensorFlow BUILTIN_REF on one static fixture. Evidence:
`docs/validation/20261007-tinyml/cache-restored-static-strict-debug.json`.
Its roughly 4.4-second UART-profiled run does not satisfy real-time acceptance.
The optimized RGBA640 model has also completed all 10 hardware operations with
exact 1,228,800-byte equality to its own BUILTIN_REF fixture. Invoke takes
1.37987371 seconds at 100 MHz, excluding profile UART transmission; it does
not meet 15 fresh style frames/s. Evidence:
`docs/validation/20261007-tinyml/rgba640-static-strict-debug.json`.
The associated SRAM bitstream passed Efinity setup +0.030 ns / hold +0.024 ns
and uses 59,740 XLRs, 236 RAM blocks and 54 DSPs. Flash remains unchanged.

## Build

The sibling `../tinyml` checkout is pinned to official revision
`96886fa0c73e25e6218db7d0863f84677cf65138`. Its runtime and accelerator archive
remain unchanged. Narrow licensed source overrides live in `src/overrides`:
Conv/Add reject fallback, MicroInterpreter propagates Init/Prepare errors, and
MicroGraph checks immutable node-vector pointers before dereferencing them.
Allocation tracing remains enabled before Invoke and is excluded from its timing.

Run from the Iris repository root:

```sh
.script/build-tinyml-firmware check-model
.script/build-tinyml-firmware \
  STANDALONE="$PWD/iris_ws/embedded_sw/SapphireSoc/software/standalone" \
  BSP_PATH="$PWD/iris_ws/embedded_sw/SapphireSoc/bsp/efinix/EfxSapphireSoc" \
  RISCV_BIN=/home/noir/Applications/riscv-none-elf/bin/riscv-none-elf- \
  DDR_BASE=0x00800000 DDR_BYTES=0x02000000 STRICT_DISPATCH=1 -j8
```

`STRICT_DISPATCH=0` is a diagnostic software-permitting build. Do not use it as
hardware-only acceptance evidence. The board build must match the generated
Iris BSP: RV32IM soft-float, one hart, 100 MHz core/peripheral clocks, 16 KiB OCR,
and 1 KiB instruction/data caches (original parity used 4 KiB). The vendor archive requires Sapphire's
data-cache flush instruction; disabling the CPU cache causes an illegal instruction. The installed xPack GCC 12.3
and Efinity 2026.1 are used; the actual generated syscall file is `syscalls.c`.
The build records compiler, flags, BSP, archive, and model hashes.

The linker reserves image/BSS, a 2 MiB heap, and a 64-byte-aligned 2 MiB tensor
arena in the explicit DDR window. Its 8 KiB control stack is in OCR
`[0xf9002000,0xf9004000)`. A DDR image loader must initialize storage and enter
`_start`; this ELF is not a Flash bootloader. The arena is NOLOAD, outside BSS
clear and the libc heap. No CPU boot image has been committed to Flash here.

## Static fixture and acceptance

The checked-in original 125336-byte model is unchanged: INT8 NHWC
`[1,128,128,3]`, input scale 1 / zero point -128, 16 Conv, 5 Add, 2 Resize nodes.
A gradient/checkerboard fixture is filled directly in its input tensor.
`iris_result` is debugger-readable: word 0 is 1=running, 2=output-ready,
3=stopped; word 1 is the initialization phase; words 2/3 are output address/size,
word 4 is FNV-1a, words 5/6 are CLINT ticks. Status 2 requires successful Invoke.
A checksum or capability print is not a numeric-parity result. The new profiler records during Invoke and prints afterward, excluding UART
transmission from timing. The original parity evidence predates this change.
Neither a single static Invoke nor HDMI refresh establishes fresh-frame throughput.

The CPU has a native 128-bit DDR line adapter, preserving WSTRB for sub-word
stores and returning full lines to Sapphire's upstream lane selector. The DDR
arbiter protects video ownership/ranges. The shared address bridge now retains
AW/AR selection until acceptance under backpressure. A pipelined write stream is blocked after LAST until its B response releases
ownership. Without that gate, later W data can precede its address. Independent
read/write operation remains enabled; transaction serialization is a diagnostic
parameter only and its board run encountered a startup stall.

## Hardware resize ABI

Custom function-ID bit 9 selects Iris; vendor IDs remain separate. These are
function IDs, not bit positions in the RISC-V instruction word.

| ID | Operation | Operands/result |
| --- | --- | --- |
| 0x200 | Capability | returns 0x49520101 |
| 0x201 | Addresses | rs1=source, rs2=destination |
| 0x202 | Shape | rs1=input height, rs2=input width |
| 0x203 | Channels | rs1=4, 8, 16, or 32 |
| 0x204 | Start | 0=accepted, FFFFFFFE=busy, FFFFFFFF=invalid |
| 0x205 | Status | bit 0=busy, bit 1=done, bit 2=error, bits 8+=error code |
| 0x206 | Abort | drains outstanding AXI response before idle |

Input/output are disjoint, 16-byte-aligned contiguous NHWC INT8. Rows must be
multiples of 16 bytes; input H/W range is 1..1024. Output H/W are exactly doubled,
quantization is unchanged, and both TensorFlow resize flags are false.
`out[y,x,c]=in[y/2,x/2,c]`. Address/size validation is pipelined. Invalid requests
emit no DMA; completion requires the final successful B response. Vendor and
Iris DMA cannot acquire ownership while the other has an outstanding request.
The firmware writes back/invalidates CPU cache and resets TinyML cache at DMA boundaries and aborts on its CLINT
one-second timeout. It never uses software resize after an error.

## Reproducible board diagnostic

After an Efinity build with passing timing, `.script/sync-iris jtag` changes SRAM
only. Stop OpenOCD before programming, then start Efinity's bundled OpenOCD with
`.script/openocd_ftdi_iris.cfg` and the generated `debug_ti.cfg`.

```sh
.script/probe-iris-ddr --execute-ddr --stress-pipeline \
  --base 0x00700000 --output docs/validation/20261007-tinyml/ddr-stress.json
```

This requires an already running OpenOCD Tcl server on port 6666. It overwrites
the selected 64 KiB test window and halts the CPU afterward; do not run against
a live arena occupying that window. Word/halfword/byte tests, sparse neighboring
lane preservation, random scatter writes, a three-second retention test, and
four distinct DDR instructions must all pass. BRAM result word 0 must be
`600d0001`, word 15 `12345679`, and error counters zero. `--execute-ddr` covers
concurrent instruction/data traffic; `--stress-pipeline` adds firmware-like O3
unrolled loops. JSON records compile arguments, ELF/bit-file/source digests and
raw board results. Link the bit-file digest to the separate programming report
before making any loaded-image provenance claim.

The static model runner loads the ELF, captures the complete stop message,
reads the descriptor, and dumps output only after successful Invoke:

```sh
.script/run-tinyml-bringup --timeout 90 \
  --output docs/validation/20261007-tinyml/static-strict \
  --golden one_last_kiss_style/build/golden-0.bin
```

Its parity record distinguishes exact equality, maximum error, MAE, and byte
mismatches. No numeric tolerance is silently treated as an exact pass.

## Still required

640x480 model output parity and measured
fresh-frame throughput; hardware camera crop/preprocess and ownership; neural
output postprocess/HDMI comparison; Flash loader, readback and cold-boot proof.
The trained low-decoder model is preserved in `one_last_kiss_style/models`;
official model arrays are in `iris_ws/RISC-V/rgba640`. Source configuration is
now 4x2/CounterDepth640 for the camera demo; its board validation is separate from original parity.
Build with `MODEL_PROFILE=rgba640` (4 MiB arena), or `original` (2 MiB).
The safe firmware scratch window is `[0x00700000,0x00710000)`. See `docs/validation/20261007-tinyml` for measured
results and failures. RTL passes, target links, and timing passes do not imply
end-to-end visual or performance acceptance.

## Low-rate camera demo (bring-up in progress)

Build `MODEL_PROFILE=rgba640 LIVE_DEMO=1 STRICT_DISPATCH=1`. The current source
uses hardware DMA tensor transport around Invoke, retaining the statically
validated arena addresses. CPU code configures transport and operators; it does
not copy, quantize or process image pixels. CI 0x208 performs an unchanged tensor
copy with the same alignment, range, overlap, final-B and abort rules as resize;
0x204 retains nearest-neighbour 2x behavior.

APB0 at `0xf8100000` exposes capture/commit controls, pair ownership and counters.
Input banks are `0x03000000` / `0x03200000`; output banks are `0x03400000` /
`0x03600000`, each containing 1,228,800 RGBA INT8 bytes. Only the inactive pair
is captured and written. Commit changes both panels at VS; acknowledgement
precedes reuse. The panels show matched 640x480 input and style on 1080p output.
OCR control data uses `[0xf9001000,0xf9002000)`; the stack remains in the upper
8 KiB. The licensed MicroProfiler header override caps events at 24, rebuilt
consistently across source objects, to fit control data in OCR.

The demo profile reduces the KEY2/UART-C thumbnail to 48x27 to save RAM;
exposure and AWB remain available. Non-demo defaults retain 96x54.

After a successful fresh Efinity build/timing check, stop OpenOCD and program
SRAM with `.script/sync-iris jtag`, restart the official OpenOCD server, then:

```sh
.script/run-iris-style-demo --seconds 25 --snapshot \
  --output docs/validation/20261007-tinyml/camera-demo
.venv-style/bin/python .script/verify-style-snapshot.py \
  docs/validation/20261007-tinyml/camera-demo
```

The runner records committed pair rate separately from HDMI refresh and saves
active input/output snapshots for independent integer-reference parity. Use
`--attach` to observe an already running firmware. After a failed DMA/cache run,
reload SRAM before loading another ELF: warm reset has not reliably restored
execution. Current live bring-up is not yet accepted; Flash is unchanged.
