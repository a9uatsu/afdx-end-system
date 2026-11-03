// =============================================================================
// 文件名  : afdx_frame_tx.v
// 模块    : afdx_frame_tx
// 功能    : AFDX 发送帧组装与发送（直接驱动 8 位 MAC 发送总线）
//           帧结构（字段大端，FCS 小端）：
//             [0:5]  目的 MAC     [6:11] 源 MAC     [12:13] EtherType=0x0800
//             [14:33] IPv4 头(20B)            [34:41] UDP 头(8B)
//             [42:43] VLID(2B)  [44] SN(1B)  [45..] 功能数据
//             0x00 填充至最小帧                最后 4 字节 FCS
//           发送前依次算完：IPv4 校验和 -> UDP 校验和 -> 整帧 CRC-32，
//           然后连续流式发送，帧内不留空隙（空闲即帧边界，见 defs 约定）
// =============================================================================
`include "afdx_defs.vh"

module afdx_frame_tx #(
    parameter IFG_CYCLES = 16        // 帧间最小空隙（时钟周期）
) (
    input  wire        clk,
    input  wire        reset,
    // ---- 帧请求（脉冲，仅在 IDLE 被接收） ----
    input  wire        req,
    input  wire [15:0] req_vlid,
    input  wire [7:0]  req_sn,
    input  wire [10:0] req_data_len,
    input  wire [31:0] req_src_ip,
    input  wire [31:0] req_dst_ip,
    input  wire [15:0] req_src_port,
    input  wire [15:0] req_dst_port,
    input  wire [47:0] req_src_mac,
    input  wire [47:0] req_dst_mac,
    // ---- MAC 发送总线 ----
    output wire [7:0]  mac_tx_data,
    output wire        mac_tx_valid,
    input  wire        mac_tx_ready,
    // ---- 状态与调试 ----
    output reg         busy,
    output reg         done,          // 脉冲：一帧发送完成
    output reg  [15:0] frame_len,     // 本帧总字节数（含 FCS）
    output reg  [15:0] ip_ck_dbg,
    output reg  [15:0] udp_ck_dbg,
    output reg  [31:0] fcs_dbg
);

    // ---------------- 状态编码 ----------------
    localparam [4:0]
        S_IDLE  = 5'd0,
        S_HDR   = 5'd1,
        S_IP_I  = 5'd2,  S_IP_F  = 5'd3,  S_IP_L  = 5'd4,  S_IP_L2 = 5'd5,
        S_UD_I  = 5'd6,  S_UD_P  = 5'd7,  S_UD_H  = 5'd8,  S_UD_F  = 5'd9,
        S_UD_L  = 5'd10, S_UD_L2 = 5'd11,
        S_CRC_I = 5'd12, S_CRC_F = 5'd13, S_CRC_L = 5'd14,
        S_SEND  = 5'd15, S_IFG   = 5'd16;

    reg [4:0] state;

    // ---------------- 请求锁存 ----------------
    reg [15:0] t_vlid;
    reg [7:0]  t_sn;
    reg [10:0] t_dlen;
    reg [31:0] t_src_ip, t_dst_ip;
    reg [15:0] t_src_port, t_dst_port;
    reg [47:0] t_src_mac, t_dst_mac;

    reg [7:0]  hdr [0:41];            // 固定头部 42 字节
    reg [31:0] fcs_q;
    reg [11:0] pad_n;
    reg [11:0] cnt;
    reg [3:0]  ps_i;
    reg [15:0] ifg_cnt;

    wire [11:0] pay_total = {1'b0, t_dlen} + 12'd3;        // VLID+SN+功能数据
    wire [11:0] body_len  = 12'd42 + pay_total + pad_n;    // 不含 FCS
    wire [11:0] total_len = body_len + 12'd4;              // 含 FCS
    wire [1:0]  fcs_i     = cnt[1:0] - body_len[1:0];      // FCS 字节序号

    // =========================================================================
    // 组合字节生成（统一用 always @(*) 组合块，避免连续赋值中调用函数的
    // 敏感度问题；三种总线字节：伪首部 / 载荷 / 帧体+填充 / FCS）
    // =========================================================================
    wire [15:0] ulen_w   = pay_total + 16'd8;      // UDP 长度字段
    wire [15:0] ip_len_w = pay_total + 16'd28;     // IPv4 总长度字段

    // ---- ① 帧体字节（第 bb_k 字节）：头部 -> 载荷 -> 0x00 填充 ----
    wire [11:0] bb_k    = cnt;
    wire [11:0] bb_p    = bb_k - 12'd42;           // 载荷内序号
    wire [10:0] bb_didx = (bb_p >= 12'd3) ? (bb_p[10:0] - 11'd3) : 11'd0;
    wire [7:0]  bb_data = `AFDX_PAYLOAD_BYTE(t_vlid, bb_didx, t_sn);
    reg  [7:0]  body_byte_q;
    always @(*) begin
        if (bb_k < 12'd42)
            body_byte_q = hdr[bb_k[5:0]];
        else if (bb_k < (12'd42 + pay_total)) begin
            if (bb_p == 12'd0)      body_byte_q = t_vlid[15:8];
            else if (bb_p == 12'd1) body_byte_q = t_vlid[7:0];
            else if (bb_p == 12'd2) body_byte_q = t_sn;
            else                    body_byte_q = bb_data;
        end else
            body_byte_q = 8'h00;
    end

    // ---- ② UDP 校验和阶段的载荷字节（序号 = cnt） ----
    wire [10:0] ck_didx = (cnt >= 12'd3) ? (cnt[10:0] - 11'd3) : 11'd0;
    wire [7:0]  ck_data = `AFDX_PAYLOAD_BYTE(t_vlid, ck_didx, t_sn);
    reg  [7:0]  pay_byte_q;
    always @(*) begin
        if (cnt == 12'd0)      pay_byte_q = t_vlid[15:8];
        else if (cnt == 12'd1) pay_byte_q = t_vlid[7:0];
        else if (cnt == 12'd2) pay_byte_q = t_sn;
        else                   pay_byte_q = ck_data;
    end

    // ---- ③ UDP 伪首部 12 字节 ----
    reg [7:0] pseudo_byte_q;
    always @(*) begin
        case (ps_i)
            4'd0:    pseudo_byte_q = t_src_ip[31:24];
            4'd1:    pseudo_byte_q = t_src_ip[23:16];
            4'd2:    pseudo_byte_q = t_src_ip[15:8];
            4'd3:    pseudo_byte_q = t_src_ip[7:0];
            4'd4:    pseudo_byte_q = t_dst_ip[31:24];
            4'd5:    pseudo_byte_q = t_dst_ip[23:16];
            4'd6:    pseudo_byte_q = t_dst_ip[15:8];
            4'd7:    pseudo_byte_q = t_dst_ip[7:0];
            4'd8:    pseudo_byte_q = 8'h00;
            4'd9:    pseudo_byte_q = `IPV4_PROTO_UDP;
            4'd10:   pseudo_byte_q = ulen_w[15:8];
            4'd11:   pseudo_byte_q = ulen_w[7:0];
            default: pseudo_byte_q = 8'h00;
        endcase
    end

    // ---- ④ FCS 字节（小端发送） ----
    reg [7:0] fcs_byte_q;
    always @(*) begin
        case (fcs_i[1:0])
            2'd0:    fcs_byte_q = fcs_q[7:0];
            2'd1:    fcs_byte_q = fcs_q[15:8];
            2'd2:    fcs_byte_q = fcs_q[23:16];
            default: fcs_byte_q = fcs_q[31:24];
        endcase
    end

    // =========================================================================
    // 子模块实例
    // =========================================================================
    wire        ck_ip_init = (state == S_IP_I);
    wire        ck_ip_en   = (state == S_IP_F);
    wire        ck_ip_fin  = (state == S_IP_L);
    wire [7:0]  ck_ip_din  = hdr[6'd14 + cnt[5:0]];
    wire [15:0] ck_ip_sum;
    wire        ck_ip_valid;

    afdx_checksum16 u_ck_ip (
        .clk(clk), .reset(reset),
        .init(ck_ip_init), .en(ck_ip_en), .din(ck_ip_din),
        .finalize(ck_ip_fin), .udp_zero_to_ones(1'b0),
        .checksum(ck_ip_sum), .valid(ck_ip_valid)
    );

    wire        ck_ud_init = (state == S_UD_I);
    wire        ck_ud_en   = (state == S_UD_P) || (state == S_UD_H) || (state == S_UD_F);
    wire        ck_ud_fin  = (state == S_UD_L);
    wire [7:0]  ck_ud_din  = (state == S_UD_P) ? pseudo_byte_q :
                             (state == S_UD_H) ? ((cnt < 16'd6) ? hdr[6'd34 + cnt[5:0]] : 8'h00) :
                                                 pay_byte_q;
    wire [15:0] ck_ud_sum;
    wire        ck_ud_valid;

    afdx_checksum16 u_ck_ud (
        .clk(clk), .reset(reset),
        .init(ck_ud_init), .en(ck_ud_en), .din(ck_ud_din),
        .finalize(ck_ud_fin), .udp_zero_to_ones(1'b1),
        .checksum(ck_ud_sum), .valid(ck_ud_valid)
    );

    wire        crc_init = (state == S_CRC_I);
    wire        crc_en   = (state == S_CRC_F);
    wire [7:0]  crc_din  = body_byte_q;
    wire [31:0] crc_fcs;

    afdx_crc32 u_crc (
        .clk(clk), .reset(reset), .init(crc_init), .en(crc_en),
        .din(crc_din), .crc(), .fcs(crc_fcs)
    );

    // ---------------- 发送呈现 ----------------
    assign mac_tx_valid = (state == S_SEND);
    assign mac_tx_data  = (cnt < body_len) ? body_byte_q : fcs_byte_q;

    // =========================================================================
    // 主状态机
    // =========================================================================
    integer i;

    always @(posedge clk) begin
        if (reset) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            frame_len  <= 16'd0;
            ip_ck_dbg  <= 16'h0;
            udp_ck_dbg <= 16'h0;
            fcs_dbg    <= 32'h0;
            cnt        <= 12'd0;
            ps_i       <= 4'd0;
            ifg_cnt    <= 16'd0;
            pad_n      <= 12'd0;
            t_vlid     <= 16'h0; t_sn <= 8'h0; t_dlen <= 11'h0;
            t_src_ip   <= 32'h0; t_dst_ip <= 32'h0;
            t_src_port <= 16'h0; t_dst_port <= 16'h0;
            t_src_mac  <= 48'h0; t_dst_mac <= 48'h0;
            fcs_q      <= 32'h0;
            for (i = 0; i < 42; i = i + 1) hdr[i] <= 8'h00;
        end else begin
            done <= 1'b0;

            case (state)
            // ---------- 等待请求，锁存参数 ----------
            S_IDLE: begin
                busy <= 1'b0;
                if (req) begin
                    t_vlid     <= req_vlid;
                    t_sn       <= req_sn;
                    t_dlen     <= req_data_len;
                    t_src_ip   <= req_src_ip;
                    t_dst_ip   <= req_dst_ip;
                    t_src_port <= req_src_port;
                    t_dst_port <= req_dst_port;
                    t_src_mac  <= req_src_mac;
                    t_dst_mac  <= req_dst_mac;
                    // 填充长度：保证 (42 + pay_total + pad + 4) >= 64
                    pad_n      <= ((12'd45 + {1'b0, req_data_len}) < 12'd60) ?
                                  (12'd60 - 12'd45 - {1'b0, req_data_len}) : 12'd0;
                    state      <= S_HDR;
                    busy       <= 1'b1;
                end
            end

            // ---------- 组装固定头部 ----------
            S_HDR: begin
                hdr[0]  <= t_dst_mac[47:40]; hdr[1]  <= t_dst_mac[39:32];
                hdr[2]  <= t_dst_mac[31:24]; hdr[3]  <= t_dst_mac[23:16];
                hdr[4]  <= t_dst_mac[15:8];  hdr[5]  <= t_dst_mac[7:0];
                hdr[6]  <= t_src_mac[47:40]; hdr[7]  <= t_src_mac[39:32];
                hdr[8]  <= t_src_mac[31:24]; hdr[9]  <= t_src_mac[23:16];
                hdr[10] <= t_src_mac[15:8];  hdr[11] <= t_src_mac[7:0];
                hdr[12] <= `ETH_TYPE_IPV4_HI;
                hdr[13] <= `ETH_TYPE_IPV4_LO;
                hdr[14] <= `IPV4_VERSION_IHL;
                hdr[15] <= `IPV4_TOS;
                hdr[16] <= ip_len_w[15:8];
                hdr[17] <= ip_len_w[7:0];
                hdr[18] <= `IPV4_ID_HI;
                hdr[19] <= `IPV4_ID_LO;
                hdr[20] <= `IPV4_FLAGS_FRAG_HI;
                hdr[21] <= `IPV4_FLAGS_FRAG_LO;
                hdr[22] <= `IPV4_TTL;
                hdr[23] <= `IPV4_PROTO_UDP;
                hdr[24] <= 8'h00;                 // IPv4 校验和占位
                hdr[25] <= 8'h00;
                hdr[26] <= t_src_ip[31:24];  hdr[27] <= t_src_ip[23:16];
                hdr[28] <= t_src_ip[15:8];   hdr[29] <= t_src_ip[7:0];
                hdr[30] <= t_dst_ip[31:24];  hdr[31] <= t_dst_ip[23:16];
                hdr[32] <= t_dst_ip[15:8];   hdr[33] <= t_dst_ip[7:0];
                hdr[34] <= t_src_port[15:8]; hdr[35] <= t_src_port[7:0];
                hdr[36] <= t_dst_port[15:8]; hdr[37] <= t_dst_port[7:0];
                hdr[38] <= ulen_w[15:8];
                hdr[39] <= ulen_w[7:0];
                hdr[40] <= 8'h00;                 // UDP 校验和占位
                hdr[41] <= 8'h00;
                frame_len <= total_len;
                state <= S_IP_I;
            end

            // ---------- IPv4 头校验和（20 字节） ----------
            S_IP_I:  begin cnt <= 12'd0; state <= S_IP_F; end
            S_IP_F:  begin
                if (cnt == 12'd19) state <= S_IP_L;
                else               cnt   <= cnt + 12'd1;
            end
            S_IP_L:  state <= S_IP_L2;
            S_IP_L2: begin
                hdr[24]   <= ck_ip_sum[15:8];
                hdr[25]   <= ck_ip_sum[7:0];
                ip_ck_dbg <= ck_ip_sum;
                state     <= S_UD_I;
            end

            // ---------- UDP 校验和（伪首部 + UDP 头 + 载荷） ----------
            S_UD_I:  begin ps_i <= 4'd0; cnt <= 12'd0; state <= S_UD_P; end
            S_UD_P:  begin
                if (ps_i == 4'd11) state <= S_UD_H;
                else               ps_i  <= ps_i + 4'd1;
            end
            S_UD_H:  begin
                if (cnt == 12'd7) begin cnt <= 12'd0; state <= S_UD_F; end
                else                  cnt <= cnt + 12'd1;
            end
            S_UD_F:  begin
                if (cnt == (pay_total - 12'd1)) begin cnt <= 12'd0; state <= S_UD_L; end
                else                                cnt <= cnt + 12'd1;
            end
            S_UD_L:  state <= S_UD_L2;
            S_UD_L2: begin
                hdr[40]    <= ck_ud_sum[15:8];
                hdr[41]    <= ck_ud_sum[7:0];
                udp_ck_dbg <= ck_ud_sum;
                state      <= S_CRC_I;
            end

            // ---------- 整帧 CRC-32（头部 + 载荷 + 填充） ----------
            S_CRC_I: begin cnt <= 12'd0; state <= S_CRC_F; end
            S_CRC_F: begin
                if (cnt == (body_len - 12'd1)) state <= S_CRC_L;
                else                           cnt   <= cnt + 12'd1;
            end
            S_CRC_L: begin
                fcs_q   <= crc_fcs;
                fcs_dbg <= crc_fcs;
                cnt     <= 12'd0;
                state   <= S_SEND;
            end

            // ---------- 连续流式发送（帧内不留空隙） ----------
            S_SEND: begin
                if (mac_tx_ready) begin
                    if (cnt == (total_len - 12'd1)) begin
                        ifg_cnt <= 16'd0;
                        state   <= S_IFG;
                    end else begin
                        cnt <= cnt + 12'd1;
                    end
                end
            end

            // ---------- 帧间空隙（保证帧边界可识别） ----------
            S_IFG: begin
                if (ifg_cnt >= (IFG_CYCLES - 1)) begin
                    state <= S_IDLE;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                end else begin
                    ifg_cnt <= ifg_cnt + 16'd1;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
