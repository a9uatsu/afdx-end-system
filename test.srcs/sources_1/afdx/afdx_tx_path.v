// =============================================================================
// 文件名  : afdx_tx_path.v
// 模块    : afdx_tx_path
// 功能    : AFDX 发送通路集成（支持 128 VL）
//
// 流水：
//   TX VL 表 RAM + 后台 4 VL/拍扫描 -> 就绪 FIFO/轮询授权
//   -> 单路同步读出 VL 记录 -> 待发寄存器 -> 帧组装/MAC 发送
// =============================================================================
`include "afdx_defs.vh"

module afdx_tx_path #(
    parameter N_VL       = 128,
    parameter VW         = 7,
    parameter SW         = 5,
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
    input  wire               enable,
    // ---- MAC 发送总线 ----
    output wire [7:0]         mac_tx_data,
    output wire               mac_tx_valid,
    input  wire               mac_tx_ready,
    // ---- 状态与观测 ----
    output wire               busy,
    output wire               frame_done,
    output wire [VW-1:0]      done_vl,
    output wire [15:0]        frame_len,
    output wire [15:0]        dbg_ip_ck,
    output wire [15:0]        dbg_udp_ck,
    output wire [31:0]        dbg_fcs,
    output wire [15:0]        tx_frame_cnt
);

    // ---------------- VL 表与调度器互联 ----------------
    wire [SW-1:0] scan_addr;
    wire [3:0]    scan_en;
    wire          grant;
    wire [VW-1:0] grant_vl;
    wire          dispatch_valid;
    wire [251:0]  dispatch_record;

    afdx_vl_table #(.N_VL(N_VL), .VW(VW), .SW(SW)) u_vlt (
        .clk(clk), .reset(reset),
        .cfg_wr(cfg_wr), .cfg_vl(cfg_vl), .cfg_field(cfg_field), .cfg_data(cfg_data),
        .scan_addr(scan_addr), .scan_en(scan_en),
        .dispatch_req(grant), .dispatch_vl(grant_vl),
        .dispatch_valid(dispatch_valid), .dispatch_record(dispatch_record)
    );

    // ---------------- 待发记录 ----------------
    reg               pend;
    reg [VW-1:0]      pend_vl;
    reg [15:0]        pend_vlid;
    reg [10:0]        pend_len;
    reg [31:0]        pend_bag;
    reg [31:0]        pend_src_ip, pend_dst_ip;
    reg [15:0]        pend_src_port, pend_dst_port;
    reg [47:0]        pend_src_mac, pend_dst_mac;

    reg               disp_active;
    reg [VW-1:0]      disp_vl;

    wire [VW-1:0] sel_vl = pend_vl;
    wire [7:0] cur_sn;

    afdx_sn_gen #(.N_VL(N_VL), .VW(VW)) u_sn (
        .clk(clk), .reset(reset), .init(1'b0),
        .inc_en(frame_done), .inc_vl(done_vl),
        .rd_vl(sel_vl), .rd_sn(cur_sn)
    );

    wire ftx_busy;
    wire req = pend & ~ftx_busy;

    afdx_scheduler #(.N_VL(N_VL), .VW(VW), .SW(SW), .CW(CW)) u_sched (
        .clk(clk), .reset(reset), .enable(enable),
        .scan_en(scan_en), .scan_inhibit(disp_active | req),
        .scan_addr(scan_addr),
        .start_ack(req), .start_vl(pend_vl), .start_bag(pend_bag),
        .allow_start(~ftx_busy & ~pend & ~disp_active),
        .grant(grant), .grant_vl(grant_vl)
    );

    afdx_frame_tx #(.IFG_CYCLES(IFG_CYCLES)) u_ftx (
        .clk(clk), .reset(reset),
        .req(req),
        .req_vlid(pend_vlid), .req_sn(cur_sn), .req_data_len(pend_len),
        .req_src_ip(pend_src_ip), .req_dst_ip(pend_dst_ip),
        .req_src_port(pend_src_port), .req_dst_port(pend_dst_port),
        .req_src_mac(pend_src_mac), .req_dst_mac(pend_dst_mac),
        .mac_tx_data(mac_tx_data), .mac_tx_valid(mac_tx_valid), .mac_tx_ready(mac_tx_ready),
        .busy(ftx_busy), .done(frame_done), .frame_len(frame_len),
        .ip_ck_dbg(dbg_ip_ck), .udp_ck_dbg(dbg_udp_ck), .fcs_dbg(dbg_fcs)
    );

    // record 字段与 3.2 节布局对应。
    wire [207:0] rec_ident = dispatch_record[207:0];
    wire [31:0]  rec_bag   = dispatch_record[239:208];
    wire [10:0]  rec_len   = dispatch_record[250:240];

    always @(posedge clk) begin
        if (reset) begin
            pend         <= 1'b0;
            pend_vl      <= {VW{1'b0}};
            pend_vlid    <= 16'd0;
            pend_len     <= 11'd0;
            pend_bag     <= 32'd0;
            pend_src_ip  <= 32'd0;
            pend_dst_ip  <= 32'd0;
            pend_src_port<= 16'd0;
            pend_dst_port<= 16'd0;
            pend_src_mac <= 48'd0;
            pend_dst_mac <= 48'd0;
            disp_active  <= 1'b0;
            disp_vl      <= {VW{1'b0}};
        end else begin
            if (req) pend <= 1'b0;

            if (grant && !disp_active) begin
                disp_active <= 1'b1;
                disp_vl     <= grant_vl;
            end

            if (disp_active && dispatch_valid) begin
                disp_active  <= 1'b0;
                pend         <= 1'b1;
                pend_vl      <= disp_vl;
                pend_vlid    <= rec_ident[15:0];
                pend_src_mac <= rec_ident[159:112];
                pend_dst_mac <= rec_ident[207:160];
                pend_src_ip  <= rec_ident[79:48];
                pend_dst_ip  <= rec_ident[111:80];
                pend_src_port<= rec_ident[31:16];
                pend_dst_port<= rec_ident[47:32];
                pend_bag     <= rec_bag;
                pend_len     <= rec_len;
            end
        end
    end

    // 正在发送的 VL：SN 递增目标不得被后续授权改写。
    reg [VW-1:0] tx_vl;
    always @(posedge clk) begin
        if (reset)    tx_vl <= {VW{1'b0}};
        else if (req) tx_vl <= pend_vl;
    end
    assign done_vl = tx_vl;
    assign busy    = ftx_busy | disp_active;

    // ---------------- 发送帧计数 ----------------
    reg [15:0] cnt_frames;
    always @(posedge clk) begin
        if (reset) cnt_frames <= 16'd0;
        else if (frame_done) cnt_frames <= cnt_frames + 16'd1;
    end
    assign tx_frame_cnt = cnt_frames;

endmodule
