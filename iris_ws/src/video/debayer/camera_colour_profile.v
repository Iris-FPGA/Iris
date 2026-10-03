// Measured 2026-10-03, 12x9 checkerboard, five accepted RGB frames.
// Source: docs/validation/20261003-checkerboard/capture-01/profile-measurement.json
// Flash-persistent display profile. Updated from measured checkerboard data.
// BLACK_* are conservative display black points, not dark-frame sensor offsets.
module camera_colour_profile #(
 parameter [9:0] GAIN_R=470, GAIN_G=305, GAIN_B=731,
 parameter [7:0] BLACK_R=21, BLACK_G=23, BLACK_B=20
)(
 output [9:0] r_gain,g_gain,b_gain,
 output [7:0] black_r,black_g,black_b
);
assign r_gain=GAIN_R,g_gain=GAIN_G,b_gain=GAIN_B;
assign black_r=BLACK_R,black_g=BLACK_G,black_b=BLACK_B;
endmodule
