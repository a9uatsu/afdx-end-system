// =============================================================================
// 文件名  : afdx_snmp_agent.v
// 功能    : SNMP v2c Agent 兼容封装
//
// 外部端口与重构前完全一致；实现位于 afdx_snmp_agent_core。
// 支持 Get / GetNext / Set / Trap，以及多 varbind 和 GetBulk。
// =============================================================================
`include "afdx_defs.vh"

module afdx_snmp_agent #(
    parameter [47:0] COMMUNITY  = 48'h7075626c6963,
    parameter [7:0]  SYS_NAME_LEN  = 8'd7,
    parameter [7:0]  SYS_DESCR_LEN = 8'd16
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] sys_uptime,
    input  wire [31:0] cnt_tx_frames,
    input  wire [31:0] cnt_rx_frames,
    input  wire [31:0] cnt_rx_errors,
    input  wire [31:0] cnt_dup,
    input  wire [31:0] cnt_ic_err,
    input  wire [7:0]  vl_fault,
    input  wire [15:0] vl_capacity,
    input  wire        req_wr,
    input  wire [7:0]  req_data,
    input  wire        req_last,
    input  wire        req_start,
    output wire        resp_valid,
    output wire [7:0]  resp_data,
    output wire        resp_last,
    output wire        resp_begin,
    output wire [15:0] req_cnt,
    output wire [15:0] resp_cnt,
    output wire [15:0] drop_cnt,
    output wire [15:0] no_such_cnt,
    output wire        trap_valid,
    output wire [7:0]  trap_data,
    output wire        trap_last,
    output wire        trap_begin,
    output wire [15:0] trap_cnt
);

    afdx_snmp_agent_core #(
        .COMMUNITY(COMMUNITY),
        .SYS_NAME_LEN(SYS_NAME_LEN),
        .SYS_DESCR_LEN(SYS_DESCR_LEN)
    ) u_core (
        .clk(clk), .reset(reset),
        .sys_uptime(sys_uptime), .cnt_tx_frames(cnt_tx_frames),
        .cnt_rx_frames(cnt_rx_frames), .cnt_rx_errors(cnt_rx_errors),
        .cnt_dup(cnt_dup), .cnt_ic_err(cnt_ic_err),
        .vl_fault(vl_fault), .vl_capacity(vl_capacity),
        .req_wr(req_wr), .req_data(req_data), .req_last(req_last),
        .req_start(req_start),
        .resp_valid(resp_valid), .resp_data(resp_data),
        .resp_last(resp_last), .resp_begin(resp_begin),
        .req_cnt(req_cnt), .resp_cnt(resp_cnt),
        .drop_cnt(drop_cnt), .no_such_cnt(no_such_cnt),
        .trap_valid(trap_valid), .trap_data(trap_data),
        .trap_last(trap_last), .trap_begin(trap_begin), .trap_cnt(trap_cnt)
    );

endmodule
