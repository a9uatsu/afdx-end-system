// =============================================================================
// 文件名  : afdx_frame_rx.v
// 模块    : afdx_frame_rx
// 功能    : AFDX 接收帧缓存 + 逐层校验 + 字段提取 + 载荷交付
//           1) 按空闲定界把一帧捕获到内部缓冲（组合读，分布式 RAM）
//           2) 静态检查：帧长范围、目的 MAC、EtherType、IPv4 字段、
//                        UDP/IP 长度一致性、填充字节
//           3) 动态检查：CRC-32(FCS)、IPv4 头校验和（与 FCS 同一遍完成）、
//                        UDP 校验和（含伪首部，第二遍）
//           4) 提取 VLID/SN/功能数据长度，交冗余管理判定后交付载荷
// 时序约定: 解析期间 rx_ready 拉低（背压），依靠空闲定界不会丢帧
//           meta_valid 保持 1 拍 -> 冗余管理在这一拍给出判定 -> 下一拍交付
// =============================================================================
`include "afdx_defs.vh"

module afdx_frame_rx #(
    parameter BUF_BYTES  = 2048,
    parameter AW         = 11,
    parameter [47:0] EXP_DST_MAC = 48'h030000000000
) (
    input  wire        clk,
    input  wire        reset,
    // ---- MAC 接收总线 ----
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output wire        rx_ready,
    // ---- 元数据与冗余管理握手 ----
    output reg         meta_valid,     // 1 拍脉冲：vlid/sn/长度有效
    output reg  [15:0] meta_vlid,
    output reg  [7:0]  meta_sn,
    output reg  [10:0] meta_dlen,
    input  wire        rm_accept,      // 电平：本帧是否被接受（meta_valid 之后有效）
    // ---- 交付数据流（仅被接受的帧） ----
    output reg         pay_valid,
    output reg  [7:0]  pay_data,
    // ---- 结果与统计 ----
    output reg         frm_done,       // 脉冲：一帧处理结束
    output reg         frm_err,        // 脉冲：校验失败
    output reg  [3:0]  err_code,
    output reg         frm_deliv,      // 脉冲：本帧载荷已交付
    output reg  [15:0] frames_rx_cnt,  // 收到的帧数（含错误帧）
    output reg  [15:0] frames_deliv_cnt
);

    // ---------------- 错误码 ----------------
    localparam [3:0] EC_NONE   = 4'd0,
                     EC_LEN    = 4'd1,   // 帧长越界/缓冲溢出
                     EC_MAC    = 4'd2,   // 目的 MAC 不符
                     EC_ETYPE  = 4'd3,   // EtherType 不符
                     EC_IP     = 4'd4,   // IPv4 字段错
                     EC_LENSUM = 4'd5,   // UDP/IP 长度不一致
                     EC_PAD    = 4'd6,   // 填充字节非 0
                     EC_FCS    = 4'd7,   // FCS 校验错
                     EC_IPCK   = 4'd8,   // IPv4 校验和错
                     EC_UDPCK  = 4'd9;   // UDP 校验和错

    // ---------------- 帧缓存与捕获 ----------------
    reg [7:0]  mem [0:BUF_BYTES-1];
    reg [AW:0] wr_ptr;
    reg        in_frame;
    reg [15:0] f_len;
    reg        frame_pend;
    reg        overflow;

    // ---------------- 解析状态 ----------------
    localparam [4:0] R_CAP  = 5'd0,  R_PRE  = 5'd1,  R_P1_I = 5'd2,  R_P1_B = 5'd3,
                     R_P1_W = 5'd4,  R_P1_C = 5'd5,  R_P2_I = 5'd6,  R_P2_P = 5'd7,
                     R_P2_H = 5'd8,  R_P2_F = 5'd9,  R_P2_L = 5'd10, R_P2_W = 5'd11,
                     R_P2_C = 5'd12, R_META = 5'd13, R_METW = 5'd14, R_DEL  = 5'd15,
                     R_LAST = 5'd16;
    reg [4:0]  state;
    reg [15:0] idx;
    reg [3:0]  err_r;
    reg        err_any;
    reg [15:0] pay_total_r;
    reg [10:0] dlen_r;
    reg        deliv_flag;

    // ---------------- 子模块实例 ----------------
    reg         crc_init_r, crc_en_r;
    reg  [7:0]  crc_din_r;
    wire [31:0] crc_fcs_w;

    afdx_crc32 u_crc (
        .clk(clk), .reset(reset), .init(crc_init_r), .en(crc_en_r),
        .din(crc_din_r), .crc(), .fcs(crc_fcs_w)
    );

    reg         ck_init_r, ck_en_r, ck_fin_r, ck_udp_r;
    reg  [7:0]  ck_din_r;
    wire [15:0] ck_sum_w;
    wire        ck_valid_w;

    afdx_checksum16 u_ck (
        .clk(clk), .reset(reset), .init(ck_init_r), .en(ck_en_r), .din(ck_din_r),
        .finalize(ck_fin_r), .udp_zero_to_ones(ck_udp_r),
        .checksum(ck_sum_w), .valid(ck_valid_w)
    );

    // ---------------- 组合视图（缓存填好后稳定） ----------------
    wire [15:0] udp_len_w   = {mem[38], mem[39]};
    wire [15:0] pay_total_w = udp_len_w - 16'd8;
    wire [15:0] ip_tot_w    = {mem[16], mem[17]};

    wire len_bad   = (f_len < `ETH_MIN_FRAME) || (f_len > `ETH_MAX_FRAME) || overflow;
    wire mac_bad   = ({mem[0],mem[1],mem[2],mem[3],mem[4],mem[5]} !== EXP_DST_MAC);
    wire etype_bad = ({mem[12],mem[13]} !== `ETH_TYPE_IPV4);
    wire ip_bad    = (mem[14] !== `IPV4_VERSION_IHL) || (mem[23] !== `IPV4_PROTO_UDP) ||
                     (mem[22] !== `IPV4_TTL);
    wire len_sum_bad = (udp_len_w < 16'd11) ||
                       (ip_tot_w !== (udp_len_w + 16'd20)) ||
                       (f_len < (udp_len_w + 16'd38)) ||
                       ((f_len - udp_len_w - 16'd38) > 16'd15);

    // 填充字节检查
    reg  pad_bad;
    reg [3:0] p;
    always @(*) begin
        pad_bad = 1'b0;
        for (p = 0; p < 15; p = p + 1) begin
            if ((pay_total_w + 16'd42 + {12'h000, p}) < (f_len - 16'd4)) begin
                if (mem[pay_total_w[10:0] + 6'd42 + {7'h00, p}] !== 8'h00)
                    pad_bad = 1'b1;
            end
        end
    end

    wire [3:0] pre_err = len_bad    ? EC_LEN    :
                         mac_bad    ? EC_MAC    :
                         etype_bad  ? EC_ETYPE  :
                         ip_bad     ? EC_IP     :
                         len_sum_bad? EC_LENSUM :
                         pad_bad    ? EC_PAD    : EC_NONE;
    wire pre_bad = (pre_err != EC_NONE);

    // FCS / 校验和比对
    wire [31:0] fcs_rx_w = {mem[f_len-16'd1], mem[f_len-16'd2],
                            mem[f_len-16'd3], mem[f_len-16'd4]};
    wire fcs_bad  = (crc_fcs_w !== fcs_rx_w);
    wire ipck_bad = (ck_sum_w !== {mem[24], mem[25]});

    // ---------------- 捕获与背压 ----------------
    wire cap_en = (state == R_CAP);
    assign rx_ready = cap_en && !overflow;

    always @(posedge clk) begin
        if (reset) begin
            wr_ptr     <= 0;
            in_frame   <= 1'b0;
            f_len      <= 16'd0;
            frame_pend <= 1'b0;
            overflow   <= 1'b0;
        end else begin
            if (cap_en) begin
                if (rx_valid && rx_ready) begin
                    // overflow 只在本块（捕获块）中驱动，避免多驱动：
                    // 新帧首字节清零，缓冲写满则置位
                    if (!in_frame)
                        overflow <= 1'b0;
                    else if (wr_ptr >= BUF_BYTES)
                        overflow <= 1'b1;
                    if (wr_ptr < BUF_BYTES)
                        mem[wr_ptr] <= rx_data;
                    wr_ptr   <= wr_ptr + 1'b1;
                    in_frame <= 1'b1;
                end else if (in_frame) begin
                    f_len      <= wr_ptr;         // 空闲即帧边界（零扩展，勿用越界位选）
                    in_frame   <= 1'b0;
                    frame_pend <= 1'b1;
                    wr_ptr     <= 0;
                end
            end
            if (state == R_LAST)
                frame_pend <= 1'b0;
        end
    end

    // ---------------- 解析主状态机 ----------------
    always @(posedge clk) begin
        if (reset) begin
            state            <= R_CAP;
            idx              <= 16'd0;
            err_r            <= EC_NONE;
            err_any          <= 1'b0;
            meta_valid       <= 1'b0;
            meta_vlid        <= 16'd0;
            meta_sn          <= 8'd0;
            meta_dlen        <= 11'd0;
            pay_valid        <= 1'b0;
            pay_data         <= 8'd0;
            frm_done         <= 1'b0;
            frm_err          <= 1'b0;
            err_code         <= EC_NONE;
            frm_deliv        <= 1'b0;
            frames_rx_cnt    <= 16'd0;
            frames_deliv_cnt <= 16'd0;
            deliv_flag       <= 1'b0;
            crc_init_r <= 1'b0; crc_en_r <= 1'b0; crc_din_r <= 8'd0;
            ck_init_r  <= 1'b0; ck_en_r  <= 1'b0; ck_fin_r  <= 1'b0;
            ck_udp_r   <= 1'b0; ck_din_r <= 8'd0;
        end else begin
            frm_done   <= 1'b0;
            frm_err    <= 1'b0;
            frm_deliv  <= 1'b0;
            meta_valid <= 1'b0;
            pay_valid  <= 1'b0;

            case (state)
            // ---------- 捕获 ----------
            R_CAP: begin
                // 注意：overflow 的清零放在捕获块（新帧首字节）里，
                // 本块不得再驱动它，否则综合报 "multiple constant drivers"
                if (frame_pend) begin
                    frames_rx_cnt <= frames_rx_cnt + 16'd1;
                    state         <= R_PRE;
                end
            end

            // ---------- 静态检查 ----------
            R_PRE: begin
                err_r           <= pre_err;
                err_any         <= pre_bad;
                pay_total_r     <= pay_total_w;
                dlen_r          <= (udp_len_w >= 16'd11) ? (udp_len_w[10:0] - 11'd11) : 11'd0;
                idx             <= 16'd0;
                deliv_flag      <= 1'b0;
                if (pre_bad)
                    state <= R_META;         // 静态检查失败：跳过校验和计算
                else
                    state <= R_P1_I;
            end

            // ---------- 第一遍：CRC-32 + IPv4 头校验和 ----------
            R_P1_I: begin
                crc_init_r <= 1'b1;
                ck_init_r  <= 1'b1;
                ck_udp_r   <= 1'b0;
                state      <= R_P1_B;
            end
            R_P1_B: begin
                crc_init_r <= 1'b0;
                ck_init_r  <= 1'b0;
                if (idx < (f_len - 16'd4)) begin
                    crc_en_r  <= 1'b1;
                    crc_din_r <= mem[idx[10:0]];
                    if ((idx >= 16'd14) && (idx <= 16'd33)) begin
                        ck_en_r  <= 1'b1;
                        ck_din_r <= ((idx == 16'd24) || (idx == 16'd25)) ? 8'h00
                                                                        : mem[idx[10:0]];
                    end else begin
                        ck_en_r <= 1'b0;
                    end
                    idx <= idx + 16'd1;
                end else begin
                    crc_en_r <= 1'b0;
                    ck_en_r  <= 1'b0;
                    ck_fin_r <= 1'b1;          // 锁存 IPv4 校验和
                    state    <= R_P1_W;
                end
            end
            R_P1_W: begin                      // 等校验和寄存器更新
                ck_fin_r <= 1'b0;
                state    <= R_P1_C;
            end
            R_P1_C: begin
                if (!err_any) begin
                    if (fcs_bad) begin
                        err_any <= 1'b1; err_r <= EC_FCS;
                    end else if (ipck_bad) begin
                        err_any <= 1'b1; err_r <= EC_IPCK;
                    end
                end
                idx   <= 16'd0;
                state <= R_P2_I;
            end

            // ---------- 第二遍：UDP 校验和 ----------
            R_P2_I: begin
                ck_init_r <= 1'b1;
                ck_udp_r  <= 1'b1;
                state     <= R_P2_P;
            end
            R_P2_P: begin   // 伪首部 12 字节
                ck_init_r <= 1'b0;
                ck_en_r   <= 1'b1;
                case (idx)
                    16'd0:   ck_din_r <= mem[26];
                    16'd1:   ck_din_r <= mem[27];
                    16'd2:   ck_din_r <= mem[28];
                    16'd3:   ck_din_r <= mem[29];
                    16'd4:   ck_din_r <= mem[30];
                    16'd5:   ck_din_r <= mem[31];
                    16'd6:   ck_din_r <= mem[32];
                    16'd7:   ck_din_r <= mem[33];
                    16'd8:   ck_din_r <= 8'h00;
                    16'd9:   ck_din_r <= `IPV4_PROTO_UDP;
                    16'd10:  ck_din_r <= mem[38];
                    default: ck_din_r <= mem[39];
                endcase
                if (idx == 16'd11) begin
                    idx   <= 16'd0;
                    state <= R_P2_H;
                end else begin
                    idx <= idx + 16'd1;
                end
            end
            R_P2_H: begin   // UDP 头 8 字节（校验和字段清零）
                ck_en_r  <= 1'b1;
                ck_din_r <= ((idx == 16'd6) || (idx == 16'd7)) ? 8'h00
                                                              : mem[34 + idx[10:0]];
                if (idx == 16'd7) begin
                    idx   <= 16'd0;
                    state <= R_P2_F;
                end else begin
                    idx <= idx + 16'd1;
                end
            end
            R_P2_F: begin   // 载荷 pay_total 字节
                ck_en_r  <= 1'b1;
                ck_din_r <= mem[42 + idx[10:0]];
                if (idx == (pay_total_r - 16'd1)) begin
                    idx   <= 16'd0;
                    state <= R_P2_L;
                end else begin
                    idx <= idx + 16'd1;
                end
            end
            R_P2_L: begin
                ck_en_r  <= 1'b0;
                ck_fin_r <= 1'b1;
                state    <= R_P2_W;
            end
            R_P2_W: begin
                ck_fin_r <= 1'b0;
                state    <= R_P2_C;
            end
            R_P2_C: begin
                if (!err_any && (ck_sum_w !== {mem[40], mem[41]})) begin
                    err_any <= 1'b1;
                    err_r   <= EC_UDPCK;
                end
                state <= R_META;
            end

            // ---------- 元数据握手 ----------
            R_META: begin
                if (!err_any) begin
                    meta_valid <= 1'b1;
                    meta_vlid  <= {mem[42], mem[43]};
                    meta_sn    <= mem[44];
                    meta_dlen  <= dlen_r;
                    idx        <= 16'd0;
                    state      <= R_METW;      // 等冗余管理给出判定
                end else begin
                    frm_err  <= 1'b1;
                    err_code <= err_r;
                    state    <= R_LAST;
                end
            end
            R_METW: begin
                state <= R_DEL;
            end

            // ---------- 载荷交付 ----------
            R_DEL: begin
                if (rm_accept) begin
                    deliv_flag <= 1'b1;
                    if (dlen_r == 11'd0) begin
                        state <= R_LAST;               // 零长度载荷
                    end else begin
                        pay_valid <= 1'b1;
                        pay_data  <= mem[45 + idx[10:0]];
                        if (idx == (dlen_r - 11'd1)) state <= R_LAST;
                        else                         idx   <= idx + 16'd1;
                    end
                end else begin
                    state <= R_LAST;                   // 被冗余管理拒绝
                end
            end

            // ---------- 结束 ----------
            R_LAST: begin
                pay_valid <= 1'b0;
                frm_done  <= 1'b1;
                frm_deliv <= deliv_flag;
                err_any   <= 1'b0;
                err_r     <= EC_NONE;
                if (deliv_flag)
                    frames_deliv_cnt <= frames_deliv_cnt + 16'd1;
                state <= R_CAP;
            end

            default: state <= R_CAP;
            endcase
        end
    end

endmodule
