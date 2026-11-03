onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -divider {Clock and control}
add wave sim:/tb_afdx_tx/clk
add wave sim:/tb_afdx_tx/reset
add wave sim:/tb_afdx_tx/enable
add wave sim:/tb_afdx_tx/mac_tx_ready
add wave -divider {Scheduler}
add wave sim:/tb_afdx_tx/dut/u_sched/grant
add wave -radix unsigned sim:/tb_afdx_tx/dut/u_sched/grant_vl
add wave -radix unsigned sim:/tb_afdx_tx/dut/u_sched/fifo_count
add wave -divider {Frame state}
add wave -radix unsigned sim:/tb_afdx_tx/dut/u_ftx/state
add wave -radix unsigned sim:/tb_afdx_tx/dut/u_ftx/cnt
add wave -divider {MAC transmit interface}
add wave sim:/tb_afdx_tx/mac_tx_valid
add wave -radix hex sim:/tb_afdx_tx/mac_tx_data
add wave sim:/tb_afdx_tx/busy
add wave sim:/tb_afdx_tx/frame_done
add wave -radix unsigned sim:/tb_afdx_tx/done_vl
add wave -radix unsigned sim:/tb_afdx_tx/frame_len
configure wave -namecolwidth 250
configure wave -valuecolwidth 110
configure wave -timelineunits ns
run 80000 ns
wave zoom range 0 12000
update
