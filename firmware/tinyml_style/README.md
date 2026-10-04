# Iris TinyML Style Firmware

This is static-input firmware integration for the official Ti60 TFLM runtime.
It is **not dispatch-only** and has not been executed on hardware. It deliberately
uses the vendor software ResizeNearestNeighbor kernel. Conv2D and Add call the
vendor accelerator drivers, which can also select software. Every invocation
prints the vendor layer mode through `FullProfiler`; a successful Invoke or a
hardware capability report alone is not evidence that all math ran in hardware.

## Dependencies And Build

No TensorFlow, BSP, or accelerator archive is copied here. The default dependency
is the sibling `../../../tinyml` checkout, pinned to official Efinix revision
`96886fa0c73e25e6218db7d0863f84677cf65138`. Override `TINYML_ROOT` to relocate that
checkout. Keep its runtime source tree and `tinyml_lib.a` unmodified. All build
products stay in this project's ignored `build/` directory.

The runtime comes from:

```text
tinyml_hello_world/Ti60F225_tinyml_hello_world/embedded_sw/SapphireSoc/software/standalone/
  tinyml_ypd/src/tensorflow/
  tinyml_ypd/src/platform/
  common/tinyml_lib.a
```

The official checkout only supplies `tinyml_standalone.mk` and the accelerator
archive under `common/`. Generate the matching Sapphire SoC embedded software
using the vendor tools. Point `STANDALONE` at its `software/standalone` directory
and `BSP_PATH` at its generated board BSP (containing `include/soc.mk`, `soc.h`,
`bsp.h`, and `app/`). Required common files are `bsp.mk`,
`riscv64-unknown-elf.mk`, `start.S`, `trap.S`, and `syscalls.s`, as named by the
official Ti60 hello_world Makefile. A generic Efinity sample BSP is not a
substitute for Iris hardware configuration.

Run from the Iris repository root:

```sh
.script/build-tinyml-firmware check-model
.script/build-tinyml-firmware \
  STANDALONE=/absolute/generated/SapphireSoc/software/standalone \
  BSP_PATH=/absolute/generated/SapphireSoc/bsp/your-board \
  RISCV_BIN=/absolute/toolchain/bin/riscv-none-elf- \
  DDR_BASE=0x01000000 DDR_BYTES=0x00800000
```

The DDR values above illustrate an 8 MiB reservation, **not an established Iris
memory map**. The parent hardware integration must assign a real CPU-visible
window before building an image for use. The build intentionally has no default
DDR address. GNU Make and dependency paths without spaces are required. The
host check needs a C++17 compiler; firmware keeps the vendor C++11 flags.

`Makefile` imports the generated `bsp.mk` and `riscv64-unknown-elf.mk`, follows the
official source groups and TFLM defines, and uses the same startup/trap/syscall
ABI and archive. Local object rules support external source paths without
writing into the dependency checkout. The local linker replaces the BSP's
small BRAM linker layout. The vendor archive reports RV32IM plus Zicsr/Zifencei,
16-byte stack alignment, and the soft-float `ilp32` ABI; a BSP selecting hard-float
is rejected. Use the vendor GNU toolchain and generated ISA flags compatible
with that archive. The output is `build/tinyml_style.{elf,hex,bin,map}` and a
configuration/compiler/archive/model hash record in `build/config.txt`.

```sh
.script/build-tinyml-firmware STRICT_DISPATCH=1
```

This must fail. There is also a C++ `#error` guard. Defining a hypothetical
hardware flag cannot turn this into a dispatch-only build. Enabling strict mode
requires implementing resize dispatch and preventing Conv/Add CPU fallback
before executing those kernels, not merely detecting fallback after inference.

## Runtime And Memory Contract

- One RV32 Sapphire hart, hart ID 0, with the official TinyML custom-instruction
  responder connected. `init_accel(0)` reads the accelerator count and settings;
  missing active Conv/Add modes stop execution. Discovery itself is a custom
  instruction, so an absent responder may trap or stall, not return zero.
- UART terminal, CLINT base/frequency, PLIC CPU-0 context, and TinyML completion
  interrupt must match the generated BSP. The official platform dispatches
  `SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT` to `ops_drv_intr()`. The reference
  SoC settings use user interrupt A ID 6, peripheral base `0xf8000000`, UART0
  offset `0x1000`, 300 MHz CPU and 100 MHz peripherals. These are reference
  requirements to reconcile with Iris, not values discovered on an Iris board.
- A bootloader/debug loader must initialize external DDR, load the image at its
  linked address, and enter `_start`. This image does not initialize DDR and is
  not a BRAM bootloader. CPU and accelerator DMA must address the same storage;
  any address alias and cache-maintenance policy must be established in RTL/BSP.
- The entire image, model, BSS, heap, stack, and tensor arena reside in the
  explicitly supplied DDR window. `ddr.ld` reserves 2 MiB heap, 16 KiB stack,
  and a 64-byte-aligned NOLOAD arena (2 MiB by default, override `ARENA_BYTES`).
  Linker bounds prevent crossing the reservation. The arena is outside the
  startup BSS clear and outside the libc heap. `AllocateTensors()` checks actual
  capacity and logs used bytes; 2 MiB is a bring-up budget, not measured demand.
- Input/output are INT8 NHWC `[1,128,128,3]`. Input scale is 1 and zero point is
  -128. A deterministic gradient/checkerboard RGB fixture is written directly
  into the input tensor. No camera, resize/preprocess, or display path is used.
- The aligned C-array wrapper includes the existing model under
  `iris_ws/RISC-V`; it does not duplicate or modify its 125336 bytes. The shared
  host/firmware contract check verifies the FlatBuffer, I/O, op counts/versions,
  and both resize shapes/options/quantization. It is not a numeric parity test.
- The only registered ops are Conv2D v3 (16 nodes), Add v2 (5), and
  ResizeNearestNeighbor v2 (2). The old vendor resize forces half-pixel centers
  false; the contract rejects models requesting true. Profiling is enabled and
  labels software explicitly. Total CLINT time includes profiling UART overhead.
  Output FNV-1a is a diagnostic checksum with no golden expected value yet.

## Proposed Resize Interface For RTL Owner

This is a proposal only; no new custom instruction is emitted by this firmware.
Agree the IDs with the parent before implementing either side. Reserve custom
function IDs with **function-ID bit 9 = 1**, separate from the vendor space;
this does not mean setting bit 9 in the RISC-V instruction word.

| Function ID | Proposed operation | Operands / result |
| --- | --- | --- |
| `0x200` | Capability query | rs1=rs2=0; return `0x49520101` for ABI v1, 2x INT8 support |
| `0x201` | Source/destination | rs1=source physical address, rs2=destination physical address |
| `0x202` | Input dimensions | rs1=height, rs2=width |
| `0x203` | Channels | rs1=channels, rs2=0 |
| `0x204` | Start | rs1=rs2=0; clear previous completion, reject busy/invalid config |
| `0x205` | Status | rs1=rs2=0; bit0 busy, bit1 done, bit2 error |
| `0x206` | Abort/reset | rs1=rs2=0; quiesce DMA before acknowledging completion |

Proposed transfer is contiguous, non-overlapping NHWC INT8, batch 1, output
height/width exactly twice input. For every channel,
`out[y,x,c] = in[y/2,x/2,c]`; copy bits unchanged, with identical quantization,
no alignment-corner or half-pixel modes. The model uses `[1,32,32,32]` to
`[1,64,64,32]` and `[1,64,64,16]` to `[1,128,128,16]`. Input/output buffers must
meet an agreed DMA alignment (propose 16 bytes), and RTL must handle final bus
beats without overwriting adjacent tensors.

Command acceptance must always terminate, including unsupported IDs. Invalid
dimensions/addresses return an error without DMA. Done is sticky until Start or
Abort; it is asserted only after all destination writes complete. The driver
must flush/clean source and destination cache lines before launch, fence, poll
with a CLINT deadline, then invalidate output and fence before handing it to
TFLM. Error/timeout must return `kTfLiteError`; never retry using CPU resize.
Abort needs to quiesce outstanding writes before any tensor storage is reused.
Exact instruction encoding (`funct7`/`funct3`), cache operations, error return
values, and physical address translation remain parent integration decisions.

A future local resize registration can reuse vendor Prepare semantics, validate
the contract above, and invoke the driver. It must mark `layer_mode[0]` hardware
only after successful completion. Conv/Add also need fail-closed registrations
or driver wrappers: current reference kernels call the vendor drivers and enter
CPU loops after an error. The archive alone cannot establish numerical parity
or prove every model shape uses hardware.

## Verification And Remaining Blockers

Verified here: host model contract passes; `main.cc` passes a host syntax-only
check against official TFLM/platform and installed Sapphire headers (host
pointer-width/register warnings only); strict mode and missing-BSP builds fail
explicitly. The installed unrelated Ti60 TSEMAC BSP was used only to inspect
Makefile/startup conventions and check syntax, not as a valid target BSP.

No installed `riscv-none-elf-g++` or `riscv64-unknown-elf-g++` was found on PATH
or in the inspected installation trees. The matching generated Sapphire BSP,
including `syscalls.s`, is absent from the official checkout. Therefore target
compilation/linking, DDR arena allocation, DMA/cache correctness, interrupt
completion, output parity, and hardware execution are **unverified**. No board
was flashed. The downloaded IDE installer was not installed as part of this
firmware-only change.
