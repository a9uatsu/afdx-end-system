# =============================================================================
# afdx_top.sdc - AFDX_top 时序约束（50 MHz 主时钟）
#
# 用法（eLinx）：把工程约束文件设为本文件后重新 Run Implementation。
# 说明：此前未写 SDC，报告里的 Min Slack 是相对默认约束的数值；
#       应用本文件后 slack 才有实际参考意义。
# =============================================================================

create_clock -name clk -period 20.000 -waveform {0.000 10.000} [get_ports clk]

set_clock_uncertainty -setup 0.300 [get_clocks clk]
set_clock_uncertainty -hold  0.100 [get_clocks clk]

set_input_delay  -clock clk -max 2.000 [get_ports {rx_data[0] rx_data[1] rx_data[2] rx_data[3] rx_data[4] rx_data[5] rx_data[6] rx_data[7] rx_valid rx_ready reset}]
set_input_delay  -clock clk -min 0.500 [get_ports {rx_data[0] rx_data[1] rx_data[2] rx_data[3] rx_data[4] rx_data[5] rx_data[6] rx_data[7] rx_valid rx_ready reset}]
set_output_delay -clock clk -max 2.000 [get_ports {tx_data[0] tx_data[1] tx_data[2] tx_data[3] tx_data[4] tx_data[5] tx_data[6] tx_data[7] tx_valid tx_ready}]
set_output_delay -clock clk -min 0.500 [get_ports {tx_data[0] tx_data[1] tx_data[2] tx_data[3] tx_data[4] tx_data[5] tx_data[6] tx_data[7] tx_valid tx_ready}]

set_false_path -from [get_ports reset]
