// =============================================================================
// 文件名  : afdx_frame_rx.v
// 模块    : afdx_frame_rx
// 功能    : AFDX 接收帧缓存 + 逐层校验 + 字段提取 + 载荷交付
//           1) 按空闲定界把一帧捕获到双 bank 同步读缓存
//           2) 静态检查：帧长范围、目的 MAC、EtherType、IPv4 字段、
//                        UDP/IP 长度一致性、填充字节
//           3) 动态检查：CRC-32(FCS)、IPv4 头校验和、UDP 校验和
//           4) 提取 VLID/SN/功能数据长度，交冗余管理判定后交付载荷
// 时序约定: 解析期间 rx_ready 拉低（背压），依靠空闲定界不会丢帧
//           meta_valid 保持 1 拍 -> 冗余管理在这一拍给出判定 -> 下一拍交付
// 重构说明: S1 将 2048x8 分布式缓存拆成两个 1024x8 同步读 bank。
//           固定首部字段在捕获时锁存，长扫描统一采用“预取下一条地址”方式，
//           存储器读延迟为 1 拍，解析状态机按 mem_rdata 有效拍消费数据。
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
    input  wire        rm_ready,       // 脉冲：冗余管理/完整性判定完成
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

    localparam HALF_BYTES = BUF_BYTES / 2;
    localparam HDR_BYTES  = 45;        // ETH + IPv4 + UDP + VLID/SN

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

    // ---------------- 双 bank 帧缓存与捕获 ----------------
    // 两块 1024x8 共同组成 2048x8 缓存。读地址最高位选择 bank，
    // 每个 bank 只保留一个同步读端口，便于综合为内嵌 RAM。
    // 捕获与解析互斥，不会在同一拍读写同一帧缓存。
    (* ramstyle = "M4K", no_rw_check *) reg [7:0] mem_lo [0:HALF_BYTES-1];
    (* ramstyle = "M4K", no_rw_check *) reg [7:0] mem_hi [0:HALF_BYTES-1];
    reg [7:0]  hdr    [0:HDR_BYTES-1]; // 固定首部字段锁存视图
    reg [AW:0] wr_ptr;
    reg        in_frame;
    reg [15:0] f_len;
    reg        frame_pend;
    reg        overflow;
    reg [31:0] tail_r;                 // 最近 4 字节，即 FCS 的线上顺序

    // ---------------- 同步读端口 ----------------
    reg [15:0] mem_raddr;
    reg [7:0]  mem_lo_q, mem_hi_q;
    reg        mem_bank_q;
    // 两个 bank 各自使用独立输出寄存器，综合器可分别推断 RAM；
    // 寄存 bank 选择位后再做 2:1 输出选择，避免综合器把选择器误判为异步读。
    wire [7:0] mem_rdata = mem_bank_q ? mem_hi_q : mem_lo_q;

    // ---------------- 解析状态 ----------------
    localparam [4:0] R_CAP  = 5'd0,  R_PRE  = 5'd1,
                     R_PAD_I= 5'd2,  R_PAD_B= 5'd3,
                     R_P1_I = 5'd4,  R_P1_B = 5'd5,  R_P1_W = 5'd6,
                     R_IP_I = 5'd7,  R_IP_B = 5'd8,  R_IP_W = 5'd9,
                     R_P1_C = 5'd10,
                     R_P2_I = 5'd11, R_P2_P = 5'd12,
                     R_P2_L = 5'd13, R_P2_W = 5'd14, R_P2_C = 5'd15,
                     R_META = 5'd16, R_METW = 5'd17, R_DEL  = 5'd18,
                     R_LAST = 5'd19;
    reg [4:0]  state;
    reg [15:0] idx;
    reg [15:0] pad_idx;
    reg [15:0] pad_count;
    reg [15:0] ck_bytes;
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

    // ---------------- 固定首部视图（捕获时已同步锁存） ----------------
    wire [15:0] udp_len_w   = {hdr[38], hdr[39]};
    wire [15:0] pay_total_w = udp_len_w - 16'd8;
    wire [15:0] ip_tot_w    = {hdr[16], hdr[17]};
    wire [15:0] ipck_rx_w   = {hdr[24], hdr[25]};
    wire [15:0] udpck_rx_w  = {hdr[40], hdr[41]};

    wire len_bad   = (f_len < `ETH_MIN_FRAME) || (f_len > `ETH_MAX_FRAME) || overflow;
    wire mac_bad   = ({hdr[0],hdr[1],hdr[2],hdr[3],hdr[4],hdr[5]} !== EXP_DST_MAC);
    wire etype_bad = ({hdr[12],hdr[13]} !== `ETH_TYPE_IPV4);
    wire ip_bad    = (hdr[14] !== `IPV4_VERSION_IHL) || (hdr[23] !== `IPV4_PROTO_UDP) ||
                     (hdr[22] !== `IPV4_TTL);
    wire len_sum_bad = (udp_len_w < 16'd11) ||
                       (ip_tot_w !== (udp_len_w + 16'd20)) ||
                       (f_len < (udp_len_w + 16'd38)) ||
                       ((f_len - udp_len_w - 16'd38) > 16'd15);

    wire [3:0] pre_err_w = len_bad    ? EC_LEN    :
                           mac_bad    ? EC_MAC    :
                           etype_bad  ? EC_ETYPE  :
                           ip_bad     ? EC_IP     :
                           len_sum_bad? EC_LENSUM : EC_NONE;
    wire pre_bad_w = (pre_err_w != EC_NONE);

    // FCS 已由捕获阶段的 4 字节滚动寄存器保存，不再异步读 mem。
    wire fcs_bad  = (crc_fcs_w !== tail_r);
    wire ipck_bad = (ck_sum_w !== ipck_rx_w);

    // ---------------- 同步读地址生成（每条数据提前 1 拍取地址） ----------------
    always @(*) begin
        mem_raddr = 16'd0;
        case (state)
            R_PAD_I: begin
                mem_raddr = 16'd42 + pay_total_r + pad_idx;
            end
            R_P1_I: begin
                mem_raddr = 16'd0;
            end
            R_P1_B: begin
                // 消费 mem_rdata 的同一拍预取下一字节，隐藏 1 拍读延迟。
                if ((idx + 16'd1) < (f_len - 16'd4))
                    mem_raddr = idx + 16'd1;
            end
            R_P2_I: begin
                // 先预取 UDP 载荷首字节，伪首部/UDP 头从 hdr 锁存视图读取。
                mem_raddr = 16'd42;
            end
            R_P2_P: begin
                // 前 20 字节不访问缓存；idx=19 起连续预取载荷字节。
                if ((idx > 16'd18) && (idx < (ck_bytes - 16'd1)))
                    mem_raddr = 16'd23 + idx;
            end
            R_META, R_METW: begin
                mem_raddr = 16'd45;
            end
            R_DEL: begin
                if ((idx + 16'd1) < {5'd0, dlen_r})
                    mem_raddr = 16'd46 + idx;
            end
            default: begin
                mem_raddr = 16'd0;
            end
        endcase
    end

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
            tail_r     <= 32'd0;
        end else begin
            if (cap_en) begin
                if (rx_valid && rx_ready) begin
                    // 新帧首字节清零溢出标志；双 bank 写入按地址最高位选择。
                    if (!in_frame)
                        overflow <= 1'b0;
                    else if (wr_ptr >= BUF_BYTES)
                        overflow <= 1'b1;

                    if (wr_ptr < BUF_BYTES) begin
                        if (wr_ptr[AW-1])
                            mem_hi[wr_ptr[AW-2:0]] <= rx_data;
                        else
                            mem_lo[wr_ptr[AW-2:0]] <= rx_data;
                    end
                    if (wr_ptr < HDR_BYTES)
                        hdr[wr_ptr[5:0]] <= rx_data;
                    // 与 S0 的 fcs_rx_w 拼接顺序保持一致：最新字节放在最高位。
                    tail_r <= {rx_data, tail_r[31:8]};
                    wr_ptr   <= wr_ptr + 1'b1;
                    in_frame <= 1'b1;
                end else if (in_frame) begin
                    f_len      <= wr_ptr;         // 空闲即帧边界
                    in_frame   <= 1'b0;
                    frame_pend <= 1'b1;
                    wr_ptr     <= 0;
                end
            end
            if (state == R_LAST)
                frame_pend <= 1'b0;

            // 与写口放在同一时钟进程内，bank 各自使用独立输出寄存器，
            // 保持 Quartus/eLinx 可识别的简单双口 RAM 模板。
            mem_lo_q   <= mem_lo[mem_raddr[AW-2:0]];
            mem_hi_q   <= mem_hi[mem_raddr[AW-2:0]];
            mem_bank_q <= mem_raddr[AW-1];
        end
    end

    // ---------------- 解析主状态机 ----------------
    always @(posedge clk) begin
        if (reset) begin
            state            <= R_CAP;
            idx              <= 16'd0;
            pad_idx          <= 16'd0;
            pad_count        <= 16'd0;
            ck_bytes         <= 16'd0;
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
                if (frame_pend) begin
                    frames_rx_cnt <= frames_rx_cnt + 16'd1;
                    state         <= R_PRE;
                end
            end

            // ---------- 静态检查准备 ----------
            R_PRE: begin
                err_r       <= pre_err_w;
                err_any     <= pre_bad_w;
                pay_total_r <= pay_total_w;
                dlen_r      <= (udp_len_w >= 16'd11) ? (udp_len_w[10:0] - 11'd11) : 11'd0;
                ck_bytes    <= pay_total_w + 16'd20;
                pad_count   <= (f_len - 16'd4) - (pay_total_w + 16'd42);
                idx         <= 16'd0;
                pad_idx     <= 16'd0;
                deliv_flag  <= 1'b0;
                if (pre_bad_w)
                    state <= R_META;         // 首部检查失败：跳过所有扫描
                else if (((f_len - 16'd4) - (pay_total_w + 16'd42)) != 16'd0)
                    state <= R_PAD_I;
                else
                    state <= R_P1_I;
            end

            // ---------- 填充字节：同步读逐字节扫描 ----------
            R_PAD_I: begin
                state <= R_PAD_B;
            end
            R_PAD_B: begin
                if (mem_rdata !== 8'h00) begin
                    err_any <= 1'b1;
                    err_r   <= EC_PAD;
                    state   <= R_META;
                end else if (pad_idx == (pad_count - 16'd1)) begin
                    state <= R_P1_I;
                end else begin
                    pad_idx <= pad_idx + 16'd1;
                    state   <= R_PAD_I;
                end
            end

            // ---------- 第一遍：CRC-32（流水地址预取） ----------
            R_P1_I: begin
                crc_init_r <= 1'b1;
                crc_en_r   <= 1'b0;
                idx        <= 16'd0;
                state      <= R_P1_B;
            end
            R_P1_B: begin
                crc_init_r <= 1'b0;
                crc_en_r   <= 1'b1;
                crc_din_r  <= mem_rdata;
                if (idx == (f_len - 16'd5))
                    state <= R_P1_W;
                else
                    idx <= idx + 16'd1;
            end
            R_P1_W: begin
                crc_en_r <= 1'b0;
                idx      <= 16'd0;
                state    <= R_IP_I;
            end

            // ---------- IPv4 头校验和：从锁存首部读取 20 字节 ----------
            R_IP_I: begin
                ck_init_r <= 1'b1;
                ck_en_r   <= 1'b0;
                ck_fin_r  <= 1'b0;
                ck_udp_r  <= 1'b0;
                idx       <= 16'd0;
                state     <= R_IP_B;
            end
            R_IP_B: begin
                ck_init_r <= 1'b0;
                ck_en_r   <= 1'b1;
                ck_din_r  <= ((idx == 16'd10) || (idx == 16'd11)) ?
                             8'h00 : hdr[14 + idx[4:0]];
                if (idx == 16'd20) begin
                    // idx=0 完成初始化，1..19 逐字节装入，20 消费最后字节。
                    ck_en_r  <= 1'b0;
                    ck_fin_r <= 1'b1;
                    state    <= R_IP_W;
                end else begin
                    idx <= idx + 16'd1;
                end
            end
            R_IP_W: begin
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
                ck_en_r   <= 1'b0;
                ck_fin_r  <= 1'b0;
                ck_udp_r  <= 1'b1;
                idx       <= 16'd0;
                state     <= R_P2_P;
            end
            R_P2_P: begin
                ck_init_r <= 1'b0;
                ck_en_r   <= 1'b1;
                case (idx)
                    // 伪首部 12 字节
                    16'd0:   ck_din_r <= hdr[26];
                    16'd1:   ck_din_r <= hdr[27];
                    16'd2:   ck_din_r <= hdr[28];
                    16'd3:   ck_din_r <= hdr[29];
                    16'd4:   ck_din_r <= hdr[30];
                    16'd5:   ck_din_r <= hdr[31];
                    16'd6:   ck_din_r <= hdr[32];
                    16'd7:   ck_din_r <= hdr[33];
                    16'd8:   ck_din_r <= 8'h00;
                    16'd9:   ck_din_r <= `IPV4_PROTO_UDP;
                    16'd10:  ck_din_r <= hdr[38];
                    16'd11:  ck_din_r <= hdr[39];
                    // UDP 头 8 字节，校验和字段清零
                    16'd12:  ck_din_r <= hdr[34];
                    16'd13:  ck_din_r <= hdr[35];
                    16'd14:  ck_din_r <= hdr[36];
                    16'd15:  ck_din_r <= hdr[37];
                    16'd16:  ck_din_r <= hdr[38];
                    16'd17:  ck_din_r <= hdr[39];
                    16'd18:  ck_din_r <= 8'h00;
                    16'd19:  ck_din_r <= 8'h00;
                    // UDP 载荷：同步读 bank
                    default: ck_din_r <= mem_rdata;
                endcase
                if (idx == ck_bytes) begin
                    // idx=0 完成初始化，1..ck_bytes 逐字节消费。
                    ck_en_r  <= 1'b0;
                    ck_fin_r <= 1'b1;
                    state    <= R_P2_L;
                end else begin
                    idx <= idx + 16'd1;
                end
            end
            R_P2_L: begin
                ck_fin_r <= 1'b0;
                state    <= R_P2_W;
            end
            R_P2_W: begin
                state <= R_P2_C;
            end
            R_P2_C: begin
                if (!err_any && (ck_sum_w !== udpck_rx_w)) begin
                    err_any <= 1'b1;
                    err_r   <= EC_UDPCK;
                end
                state <= R_META;
            end

            // ---------- 元数据握手 ----------
            R_META: begin
                if (!err_any) begin
                    meta_valid <= 1'b1;
                    meta_vlid  <= {hdr[42], hdr[43]};
                    meta_sn    <= hdr[44];
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
                if (rm_ready)
                    state <= R_DEL;
            end

            // ---------- 载荷交付：同步读到 mem_rdata 后输出 ----------
            R_DEL: begin
                if (rm_accept) begin
                    deliv_flag <= 1'b1;
                    if (dlen_r == 11'd0) begin
                        state <= R_LAST;               // 零长度载荷
                    end else begin
                        pay_valid <= 1'b1;
                        pay_data  <= mem_rdata;
                        if (idx == ({5'd0, dlen_r} - 16'd1))
                            state <= R_LAST;
                        else
                            idx <= idx + 16'd1;
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
