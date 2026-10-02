
# D-PHY byte clock is sensor sourced (CSI IP configured at 70 MHz).
# Constrain at 100 MHz to allow margin; this is not a clock measurement.
create_clock -period 10.000 -name i_cam_ck_CLKOUT [get_ports {i_cam_ck_CLKOUT}]

# Transfers between these processing domains use FIFOs or toggle/payload
# synchronizers. The HDMI half/full-rate domains also cross only through
# u_exp_fifo; its Gray pointers must not be checked as synchronous data.
set_clock_groups -asynchronous \
    -group {core_clk ddr_pll_fb ddr_core_clk ddr_tdqss_clk ddr_tac_clk ddr_twd_clk} \
    -group {hdmi_tx_slow_clk hdmi_tx_fast_clk FB} \
    -group {hdmi_tx_half_clk} \
    -group {mipi_clk mipi_pixel_clk mipi_fb} \
    -group {gpio_clk_27m} \
    -group {i_cam_ck_CLKOUT}
