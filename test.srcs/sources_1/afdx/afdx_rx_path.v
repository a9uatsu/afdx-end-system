// =============================================================================
// 文件名  : afdx_rx_path.v
// 模块    : afdx_rx_path
// 功能    : 接收通路集成
//             MAC 总线 -> 帧缓存与校验(afdx_frame_rx) -> 冗余管理(afdx_rm_rx)
//             -> 每 VL 最后一帧缓存 + 对外交付数据流
//           交付数据流（供上层分区/测试平台观察）：
//             dly_valid 与 dly_data 逐字节有效，dly_start 标示首字节
// =============================================================================
`include "afdx_defs.vh"

module afdx_rx_path #(
    parameter N_VL        = 8,
    parameter VW          = 3,
    parameter RM_SEARCH_W = 13,
    parameter PAY_BUF     = 1536,     // 每 VL 交付缓存字节数
    parameter [47:0] EXP_DST_MAC = 48'h030000000000
) (
    input  wire            clk,
    input  wire            reset,
    // ---- MAC 接收总线 ----
    input  wire [7:0]      rx_data,
    input  wire            rx_valid,
    output wire            rx_ready,
    // ---- 接收 VL 配置 ----
    input  wire            cfg_wr,
    input  wire [VW-1:0]   cfg_vl,
    input  wire [15:0]     cfg_vlid,
    input  wire            cfg_en,
    // ---- 交付数据流 ----
    output wire            dly_valid,
    output wire            dly_start,
    output wire            dly_end,          // 脉冲：一次交付结束（含零长度载荷）
    output wire [7:0]      dly_data,
    output wire [15:0]     dly_vlid,
    output wire [7:0]      dly_sn,
    output wire [10:0]     dly_plen,         // 本次交付的载荷长度
    // ---- 统计 ----
    output wire [15:0]     rx_frames_cnt,
    output wire [15:0]     rx_deliv_cnt,
    output wire [15:0]     rx_err_cnt,
    output wire [15:0]     rm_accept_cnt,
    output wire [15:0]     rm_dup_cnt,
    output wire [15:0]     rm_oos_cnt,
    output wire [15:0]     rm_unknown_cnt,
    output wire [15:0]     ic_err_cnt,
    // ---- 按索引状态读口：不再暴露 N_VL 位宽端口 ----
    input  wire [11:0]     vl_status_idx,
    input  wire            vl_status_req,
    output wire [7:0]      vl_status_data,
    output wire            vl_status_ready,
    output wire [3:0]      last_err_code
);

    // ---------------- 解析器 ----------------
    wire        meta_valid;
    wire [15:0] meta_vlid;
    wire [7:0]  meta_sn;
    wire [10:0] meta_dlen;
    wire        rm_accept;
    wire        rm_ready;
    wire        pay_valid;
    wire [7:0]  pay_data;
    wire        frm_done, frm_err, frm_deliv;
    wire [3:0]  err_code;

    afdx_frame_rx #(.BUF_BYTES(2048), .AW(11), .EXP_DST_MAC(EXP_DST_MAC)) u_parser (
        .clk(clk), .reset(reset),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .meta_valid(meta_valid), .meta_vlid(meta_vlid), .meta_sn(meta_sn),
        .meta_dlen(meta_dlen), .rm_accept(rm_accept), .rm_ready(rm_ready),
        .pay_valid(pay_valid), .pay_data(pay_data),
        .frm_done(frm_done), .frm_err(frm_err), .err_code(err_code),
        .frm_deliv(frm_deliv),
        .frames_rx_cnt(rx_frames_cnt), .frames_deliv_cnt(rx_deliv_cnt)
    );

    // ---------------- 冗余管理 ----------------
    afdx_rm_rx #(.N_VL(N_VL), .VW(VW), .SEARCH_W(RM_SEARCH_W)) u_rm (
        .clk(clk), .reset(reset),
        .cfg_wr(cfg_wr), .cfg_vl(cfg_vl), .cfg_vlid(cfg_vlid), .cfg_en(cfg_en),
        .meta_valid(meta_valid), .meta_vlid(meta_vlid), .meta_sn(meta_sn),
        .accept(rm_accept), .rm_ready(rm_ready),
        .cnt_accept(rm_accept_cnt), .cnt_dup(rm_dup_cnt), .cnt_oos(rm_oos_cnt),
        .cnt_unknown(rm_unknown_cnt),
        .status_req(vl_status_req), .status_idx(vl_status_idx[VW-1:0]),
        .status_data(vl_status_data), .status_ready(vl_status_ready),
        .cnt_ic_err(ic_err_cnt), .rm_vlid_dbg(), .rm_idx_dbg()
    );

    // ---------------- 交付数据流 ----------------
    reg        dly_valid_r, dly_start_r, dly_end_r;
    reg [7:0]  dly_data_r;
    reg [15:0] dly_vlid_r;
    reg [7:0]  dly_sn_r;
    reg [10:0] dly_plen_r;
    reg [10:0] dly_cnt_r;
    reg [15:0] err_cnt_r;
    reg [3:0]  last_err_r;

    wire first_byte = pay_valid && (dly_cnt_r == 11'd0);

    always @(posedge clk) begin
        if (reset) begin
            dly_valid_r <= 1'b0;
            dly_start_r <= 1'b0;
            dly_end_r   <= 1'b0;
            dly_data_r  <= 8'd0;
            dly_vlid_r  <= 16'd0;
            dly_sn_r    <= 8'd0;
            dly_plen_r  <= 11'd0;
            dly_cnt_r   <= 11'd0;
            err_cnt_r   <= 16'd0;
            last_err_r  <= 4'd0;
        end else begin
            dly_start_r <= 1'b0;
            dly_end_r   <= frm_deliv;
            dly_valid_r <= pay_valid;
            // 元数据在 meta_valid 时刻锁存（零长度载荷也能被观察到）
            if (meta_valid) begin
                dly_vlid_r <= meta_vlid;
                dly_sn_r   <= meta_sn;
                dly_plen_r <= meta_dlen;
                dly_cnt_r  <= 11'd0;
            end
            if (pay_valid) begin
                if (first_byte) dly_start_r <= 1'b1;
                dly_data_r <= pay_data;
                dly_cnt_r  <= dly_cnt_r + 11'd1;
            end

            if (frm_err) begin
                err_cnt_r  <= err_cnt_r + 16'd1;
                last_err_r <= err_code;
            end
        end
    end

    assign dly_valid = dly_valid_r;
    assign dly_start = dly_start_r;
    assign dly_end   = dly_end_r;
    assign dly_data  = dly_data_r;
    assign dly_vlid  = dly_vlid_r;
    assign dly_sn    = dly_sn_r;
    assign dly_plen  = dly_plen_r;
    assign rx_err_cnt = err_cnt_r;
    assign last_err_code = last_err_r;

endmodule
