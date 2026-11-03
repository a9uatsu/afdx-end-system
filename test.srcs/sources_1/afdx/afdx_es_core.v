// =============================================================================
// 文件名  : afdx_es_core.v
// 模块    : afdx_es_core
// 功能    : AFDX 端系统核心（发送通路 + 接收通路 + 双冗余网口 + 观测端口）
//           DUAL=1 时 A/B 两路 MAC 总线同时工作：
//             发送：同一帧字节流同时送往 A、B（等速同步，等待两路 ready）
//             接收：按帧级别仲裁从 A/B 取帧（同一 VL 的两份副本由冗余管理按 SN 去重）
//           DUAL=0 时仅使用 A 路（适配赛题单 MAC 总线顶层模板）
// =============================================================================
`include "afdx_defs.vh"

module afdx_es_core #(
    parameter N_TX_VL = 4,
    parameter TVW     = 2,
    parameter N_RX_VL = 8,
    parameter RVW     = 3,
    parameter DUAL    = 0,
    parameter EN_MGMT = 1,        // 0 = 暂不综合管理通道（大数组 RAM 化之前的应急开关）
    parameter LEGACY_SNMP = 0,
    parameter [47:0] EXP_DST_MAC = 48'h030000000000
) (
    input  wire               clk,
    input  wire               reset,
    // ---- MAC A 总线 ----
    output wire [7:0]         tx_a_data,
    output wire               tx_a_valid,
    input  wire               tx_a_ready,
    input  wire [7:0]         rx_a_data,
    input  wire               rx_a_valid,
    output wire               rx_a_accept,     // 本端可接收（非空闲定界信号）
    // ---- MAC B 总线（DUAL=1 有效） ----
    output wire [7:0]         tx_b_data,
    output wire               tx_b_valid,
    input  wire               tx_b_ready,
    input  wire [7:0]         rx_b_data,
    input  wire               rx_b_valid,
    output wire               rx_b_accept,
    // ---- 发送 VL 配置 ----
    input  wire               tx_cfg_wr,
    input  wire [TVW-1:0]     tx_cfg_vl,
    input  wire [2:0]         tx_cfg_field,
    input  wire [207:0]       tx_cfg_data,
    input  wire               tx_enable,
    // ---- 接收 VL 配置 ----
    input  wire               rx_cfg_wr,
    input  wire [RVW-1:0]     rx_cfg_vl,
    input  wire [15:0]        rx_cfg_vlid,
    input  wire               rx_cfg_en,
    // ---- 观测 ----
    output wire               tx_busy,
    output wire [15:0]        tx_frames,
    output wire [15:0]        tx_frame_len,
    output wire               dly_valid,
    output wire               dly_start,
    output wire               dly_end,
    output wire [7:0]         dly_data,
    output wire [15:0]        dly_vlid,
    output wire [7:0]         dly_sn,
    output wire [10:0]        dly_plen,
    output wire [15:0]        rx_frames,
    output wire [15:0]        rx_deliv,
    output wire [15:0]        rx_err,
    output wire [15:0]        rm_accept,
    output wire [15:0]        rm_dup,
    output wire [15:0]        rm_oos,
    output wire [15:0]        rm_unknown,
    output wire [15:0]        ic_err,
    output wire [7:0]         vl_fault,
    output wire [3:0]         dbg_err_code,
    output wire [15:0]        rx_drop,
    // ---- SNMP 管理通道统计 ----
    output wire [15:0]        snmp_req,
    output wire [15:0]        snmp_resp,
    output wire [15:0]        snmp_drop,
    output wire [15:0]        snmp_nosuch
);

    wire        mgmt_busy;
    wire [7:0]  mgmt_tx_data;
    wire        mgmt_tx_valid;
    wire [11:0] vl_status_idx;
    wire        vl_status_req;
    wire [7:0]  vl_status_data;
    wire        vl_status_ready;
    wire [7:0]  mgmt_fault_snapshot;
    // 管理帧发送期间不让 AFDX 帧组装器启动，避免打断 AFDX 帧
    wire tx_ready_internal = ((DUAL != 0) ? (tx_a_ready & tx_b_ready) : tx_a_ready)
                             & ~mgmt_busy;

    // ---------------- 发送通路 ----------------
    wire [7:0] tx_data_w;
    wire       tx_valid_w;
    wire       frame_done_w;
    wire [TVW-1:0] done_vl_w;
    wire [15:0] dbg_ip_ck, dbg_udp_ck;
    wire [31:0] dbg_fcs;

    afdx_tx_path #(.N_VL(N_TX_VL), .VW(TVW), .CW(32), .IFG_CYCLES(16)) u_tx (
        .clk(clk), .reset(reset),
        .cfg_wr(tx_cfg_wr), .cfg_vl(tx_cfg_vl),
        .cfg_field(tx_cfg_field), .cfg_data(tx_cfg_data),
        .enable(tx_enable),
        .mac_tx_data(tx_data_w), .mac_tx_valid(tx_valid_w), .mac_tx_ready(tx_ready_internal),
        .busy(tx_busy), .frame_done(frame_done_w), .done_vl(done_vl_w),
        .frame_len(tx_frame_len),
        .dbg_ip_ck(dbg_ip_ck), .dbg_udp_ck(dbg_udp_ck), .dbg_fcs(dbg_fcs),
        .tx_frame_cnt(tx_frames)
    );

    // ---------------- 接收网口仲裁（DUAL 有效，管理通道与 AFDX 通道共用） ----------------
    wire use_b_mux   = (DUAL != 0) && ~rx_a_valid && rx_b_valid;
    wire [7:0] rx_data_mux  = use_b_mux ? rx_b_data  : rx_a_data;
    wire       rx_valid_mux = use_b_mux ? rx_b_valid : rx_a_valid;

    generate
    if (EN_MGMT != 0) begin : g_mgmt
    // ---------------- 管理通道（SNMP 161 / RTC 123 / 615A 10000） ----------------
    reg [18:0] tick_cnt;          // 10 ms @ 50 MHz = 500,000 周期
    reg [31:0] up_time;
    always @(posedge clk) begin
        if (reset) begin
            tick_cnt <= 19'd0;
            up_time  <= 32'd0;
        end else if (tick_cnt == 19'd499999) begin
            tick_cnt <= 19'd0;
            up_time  <= up_time + 32'd1;
        end else begin
            tick_cnt <= tick_cnt + 19'd1;
        end
    end

    afdx_mgmt_path #(.LEGACY_SNMP(LEGACY_SNMP)) u_mgmt (
        .clk(clk), .reset(reset),
        .rx_data(rx_data_mux), .rx_valid(rx_valid_mux),
        .sys_uptime(up_time), .cnt_tx_frames({16'h0, tx_frames}),
        .cnt_rx_frames({16'h0, rx_frames}), .cnt_rx_errors({16'h0, rx_err}),
        .cnt_dup({16'h0, rm_dup}), .cnt_ic_err({16'h0, ic_err}),
        .vl_capacity(16'd4096),
        .vl_status_idx(vl_status_idx), .vl_status_req(vl_status_req),
        .vl_status_data(vl_status_data), .vl_status_valid(vl_status_ready),
        .vl_fault_snapshot(mgmt_fault_snapshot),
        .tx_data(mgmt_tx_data), .tx_valid(mgmt_tx_valid), .tx_busy(mgmt_busy),
        .tx_free(~tx_busy),
        .snmp_req_cnt(snmp_req), .snmp_resp_cnt(snmp_resp),
        .snmp_drop_cnt(snmp_drop), .snmp_nosuch_cnt(snmp_nosuch)
    );

    // 管理帧优先；AFDX 帧组装器在管理帧发送期间不启动
    assign tx_a_data  = mgmt_busy ? mgmt_tx_data  : tx_data_w;
    assign tx_a_valid = mgmt_busy ? mgmt_tx_valid : tx_valid_w;
    assign tx_b_data  = DUAL ? tx_a_data  : 8'h00;
    assign tx_b_valid = DUAL ? tx_a_valid : 1'b0;
    assign vl_fault   = mgmt_fault_snapshot;
    end else begin : g_no_mgmt
        assign mgmt_busy     = 1'b0;
        assign mgmt_tx_data  = 8'h00;
        assign mgmt_tx_valid = 1'b0;
        assign tx_a_data     = tx_data_w;
        assign tx_a_valid    = tx_valid_w;
        assign tx_b_data     = DUAL ? tx_data_w  : 8'h00;
        assign tx_b_valid    = DUAL ? tx_valid_w : 1'b0;
        assign snmp_req      = 16'd0;
        assign snmp_resp     = 16'd0;
        assign snmp_drop     = 16'd0;
        assign snmp_nosuch   = 16'd0;
        assign vl_status_idx = 12'd0;
        assign vl_status_req = 1'b0;
        assign vl_fault      = 8'd0;
    end
    endgenerate

    assign rx_a_accept = ~use_b_mux;
    assign rx_b_accept =  use_b_mux;

    // ---------------- 接收通路 ----------------
    wire rx_ready_int;

    afdx_rx_path #(.N_VL(N_RX_VL), .VW(RVW), .PAY_BUF(1536),
                   .EXP_DST_MAC(EXP_DST_MAC)) u_rx (
        .clk(clk), .reset(reset),
        .rx_data(rx_data_mux), .rx_valid(rx_valid_mux), .rx_ready(rx_ready_int),
        .cfg_wr(rx_cfg_wr), .cfg_vl(rx_cfg_vl),
        .cfg_vlid(rx_cfg_vlid), .cfg_en(rx_cfg_en),
        .dly_valid(dly_valid), .dly_start(dly_start), .dly_end(dly_end),
        .dly_data(dly_data), .dly_vlid(dly_vlid), .dly_sn(dly_sn), .dly_plen(dly_plen),
        .rx_frames_cnt(rx_frames), .rx_deliv_cnt(rx_deliv), .rx_err_cnt(rx_err),
        .rm_accept_cnt(rm_accept), .rm_dup_cnt(rm_dup), .rm_oos_cnt(rm_oos),
        .rm_unknown_cnt(rm_unknown), .ic_err_cnt(ic_err),
        .vl_status_idx(vl_status_idx), .vl_status_req(vl_status_req),
        .vl_status_data(vl_status_data), .vl_status_ready(vl_status_ready),
        .last_err_code(dbg_err_code)
    );

    // 未就绪期间的接收字节计数（用于观测，合规发送端不会触发）
    reg [15:0] drop_cnt;
    always @(posedge clk) begin
        if (reset) drop_cnt <= 16'd0;
        else if (rx_valid_mux && !rx_ready_int) drop_cnt <= drop_cnt + 16'd1;
    end
    assign rx_drop = drop_cnt;

endmodule
