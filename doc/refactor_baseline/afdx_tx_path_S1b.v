// =============================================================================
// 文件名  : afdx_tx_path.v
// 模块    : afdx_tx_path
// 功能    : AFDX 发送通路集成
//             VL 配置表 -> 序列号生成 -> BAG 调度 -> 帧组装发送
//           调度授权先进入 1 级待发寄存器，帧组装器空闲时立即发起，
//           保证授权脉冲不丢失（BAG 远大于单帧发送时间，深度 1 足够）
// =============================================================================
`include "afdx_defs.vh"

module afdx_tx_path #(
    parameter N_VL       = 4,
    parameter VW         = 2,
    parameter CW         = 32,
    parameter IFG_CYCLES = 16
) (
    input  wire               clk,
    input  wire               reset,
    // ---- VL 配置写口 ----
    input  wire               cfg_wr,
    input  wire [VW-1:0]      cfg_vl,
    input  wire [2:0]         cfg_field,
    input  wire [207:0]       cfg_data,
    input  wire               enable,          // 配置完成后使能调度
    // ---- MAC 发送总线 ----
    output wire [7:0]         mac_tx_data,
    output wire               mac_tx_valid,
    input  wire               mac_tx_ready,
    // ---- 状态与观测 ----
    output wire               busy,
    output wire               frame_done,      // 脉冲：一帧发送完成
    output wire [VW-1:0]      done_vl,
    output wire [15:0]        frame_len,
    output wire [15:0]        dbg_ip_ck,
    output wire [15:0]        dbg_udp_ck,
    output wire [31:0]        dbg_fcs,
    output wire [15:0]        tx_frame_cnt
);

    // ---------------- VL 配置表 ----------------
    wire [47:0]      vlt_dst_mac, vlt_src_mac;
    wire [31:0]      vlt_dst_ip, vlt_src_ip, vlt_bag;
    wire [15:0]      vlt_dst_port, vlt_src_port, vlt_vlid;
    wire [10:0]      vlt_len;
    wire             vlt_en;
    wire [N_VL-1:0]  en_vec;
    wire [N_VL*32-1:0] bag_vec;

    // 待发 VL（用于查表与取 SN）
    reg               pend;
    reg [VW-1:0]      pend_vl;

    wire [VW-1:0]     sel_vl = pend_vl;

    afdx_vl_table #(.N_VL(N_VL), .VW(VW)) u_vlt (
        .clk(clk), .reset(reset),
        .cfg_wr(cfg_wr), .cfg_vl(cfg_vl), .cfg_field(cfg_field), .cfg_data(cfg_data),
        .rd_vl(sel_vl),
        .rd_dst_mac(vlt_dst_mac), .rd_src_mac(vlt_src_mac),
        .rd_dst_ip(vlt_dst_ip),   .rd_src_ip(vlt_src_ip),
        .rd_dst_port(vlt_dst_port), .rd_src_port(vlt_src_port),
        .rd_vlid(vlt_vlid), .rd_bag(vlt_bag), .rd_len(vlt_len), .rd_en(vlt_en),
        .en_vec(en_vec), .bag_vec(bag_vec)
    );

    // ---------------- 序列号 ----------------
    wire [7:0] cur_sn;

    afdx_sn_gen #(.N_VL(N_VL), .VW(VW)) u_sn (
        .clk(clk), .reset(reset), .init(1'b0),
        .inc_en(frame_done), .inc_vl(done_vl),
        .rd_vl(sel_vl), .rd_sn(cur_sn)
    );

    // ---------------- 调度器 ----------------
    wire            grant;
    wire [VW-1:0]   grant_vl;

    // ---------------- 帧组装发送 ----------------
    wire req = pend & ~busy;

    afdx_scheduler #(.N_VL(N_VL), .VW(VW), .CW(CW)) u_sched (
        .clk(clk), .reset(reset), .enable(enable),
        .vl_en(en_vec), .bag_vec(bag_vec),
        .start_ack(req), .start_vl(pend_vl),   // 帧真正开始发送的时刻
        .allow_start(~busy & ~pend),           // 帧组装器空闲才授权
        .grant(grant), .grant_vl(grant_vl)
    );

    afdx_frame_tx #(.IFG_CYCLES(IFG_CYCLES)) u_ftx (
        .clk(clk), .reset(reset),
        .req(req),
        .req_vlid(vlt_vlid), .req_sn(cur_sn), .req_data_len(vlt_len),
        .req_src_ip(vlt_src_ip), .req_dst_ip(vlt_dst_ip),
        .req_src_port(vlt_src_port), .req_dst_port(vlt_dst_port),
        .req_src_mac(vlt_src_mac), .req_dst_mac(vlt_dst_mac),
        .mac_tx_data(mac_tx_data), .mac_tx_valid(mac_tx_valid), .mac_tx_ready(mac_tx_ready),
        .busy(busy), .done(frame_done), .frame_len(frame_len),
        .ip_ck_dbg(dbg_ip_ck), .udp_ck_dbg(dbg_udp_ck), .fcs_dbg(dbg_fcs)
    );

    // 记录"正在发送"的 VL：SN 递增目标必须与本次发送的 VL 一致。
    // （若直接用 pend_vl，新授权可能在上一帧发送期间改写它，导致
    //   序列号递增到错误的 VL 上。）
    reg [VW-1:0] tx_vl;
    always @(posedge clk) begin
        if (reset)    tx_vl <= {VW{1'b0}};
        else if (req) tx_vl <= pend_vl;
    end
    assign done_vl = tx_vl;

    // ---------------- 待发寄存器 ----------------
    always @(posedge clk) begin
        if (reset) begin
            pend    <= 1'b0;
            pend_vl <= {VW{1'b0}};
        end else begin
            if (grant) begin
                pend    <= 1'b1;
                pend_vl <= grant_vl;
            end
            if (req) pend <= 1'b0;
        end
    end

    // ---------------- 发送帧计数 ----------------
    reg [15:0] cnt_frames;
    always @(posedge clk) begin
        if (reset) cnt_frames <= 16'd0;
        else if (frame_done) cnt_frames <= cnt_frames + 16'd1;
    end
    assign tx_frame_cnt = cnt_frames;

endmodule
