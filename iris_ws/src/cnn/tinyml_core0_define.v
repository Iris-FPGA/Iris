// Integration adapter for the official Efinix TinyML Generator output.
//
// The Generator's original file is preserved byte-for-byte in
// tinyml_core0_define.generated.v (see docs/TinyML_移植进度与待办.md).
// The official RTL (tinyml_top.v / tinyml_accelerator.v /
// tinyml_accelerator_channels.v) `include`s "tinyml_core0_define.v" and
// additionally references TML_C0_RS_MODE, while the Generator emits
// TML_C0_RESHAPE_MODE.  Map the name here, in the integration layer, without
// touching the Generator original or the official RTL sources.

`include "tinyml_core0_define.generated.v"

`ifndef TML_C0_RS_MODE
    `define TML_C0_RS_MODE `TML_C0_RESHAPE_MODE
`endif
