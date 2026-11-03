// =============================================================================
// 文件名  : afdx_mgmt_path.v
// 模块    : afdx_mgmt_path
// 功能    : SNMP 管理通道（MAC 级）
//           接收：按空闲定界捕获以太网帧 -> 检查 EtherType/IPv4/UDP 目的端口 161
//                 -> 提取 SNMP 报文送入 afdx_snmp_agent
//           发送：把 Agent 响应封装成 以太网 + IPv4 + UDP 帧（校验和/FCS 全计算）
//           地址回填：响应发回请求方的源 MAC / 源 IP / 源 UDP 端口
// 时序    : 接收帧缓存同步读；发送前多遍计算校验和，发送时帧内连续不留空隙
// =============================================================================
`include "afdx_defs.vh"

module afdx_mgmt_path #(
    parameter [47:0] ES_MAC   = 48'h020000000101,
    parameter [31:0] ES_IP    = 32'h0A000101,
    parameter [15:0] UDP_PORT = 16'd161,
    parameter [7:0]  TTL      = 8'd64
) (
    input  wire        clk,
    input  wire        reset,
    // ---- MAC 接收 ----
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    // ---- MIB ----
    input  wire [31:0] sys_uptime,
    input  wire [31:0] cnt_tx_frames,
    input  wire [31:0] cnt_rx_frames,
    input  wire [31:0] cnt_rx_errors,
    input  wire [31:0] cnt_dup,
    input  wire [31:0] cnt_ic_err,
    input  wire [15:0] vl_capacity,
    // ---- 按索引读取接收 VL 状态（前 8 个形成 SNMP 快照） ----
    output reg  [11:0] vl_status_idx,
    output reg         vl_status_req,
    input  wire [7:0]  vl_status_data,
    input  wire        vl_status_valid,
    output reg  [7:0]  vl_fault_snapshot,
    // ---- MAC 发送 ----
    output wire [7:0]  tx_data,
    output reg         tx_valid,
    output wire        tx_busy,
    input  wire        tx_free,        // AFDX 发送通路空闲（帧级互斥）
    // ---- 统计 ----
    output wire [15:0] snmp_req_cnt,
    output wire [15:0] snmp_resp_cnt,
    output wire [15:0] snmp_drop_cnt,
    output wire [15:0] snmp_nosuch_cnt
);

    // =========================================================================
    // 管理引擎公共请求信号（按 sel_engine 分发）
    //   0 = SNMP(161)   1 = ARINC 615A(10000)   2 = RTC(123)
    // =========================================================================
    reg         req_wr, req_last, req_start;
    reg  [7:0]  req_data;
    reg  [1:0]  sel_engine;

    wire snmp_wr    = (sel_engine == 2'd0) ? req_wr    : 1'b0;
    wire snmp_last  = (sel_engine == 2'd0) ? req_last  : 1'b0;
    wire snmp_start = (sel_engine == 2'd0) ? req_start : 1'b0;
    wire load_wr    = (sel_engine == 2'd1) ? req_wr    : 1'b0;
    wire load_last  = (sel_engine == 2'd1) ? req_last  : 1'b0;
    wire load_start = (sel_engine == 2'd1) ? req_start : 1'b0;
    wire rtc_wr     = (sel_engine == 2'd2) ? req_wr    : 1'b0;
    wire rtc_last   = (sel_engine == 2'd2) ? req_last  : 1'b0;
    wire rtc_start  = (sel_engine == 2'd2) ? req_start : 1'b0;

    // =========================================================================
    // SNMP 协议引擎
    // =========================================================================
    wire        resp_valid, resp_last, resp_begin;
    wire [7:0]  resp_data;
    wire        trap_valid, trap_last, trap_begin;
    wire [7:0]  trap_data;
    wire [15:0] trap_cnt;

    // 轮询前 8 个接收 VL，维护兼容 SNMP MIB vlFault 的 8 位快照。
    always @(posedge clk) begin
        if (reset) begin
            vl_status_idx     <= 12'd0;
            vl_status_req     <= 1'b0;
            vl_fault_snapshot <= 8'd0;
        end else if (vl_status_valid) begin
            if (vl_status_data[0])
                vl_fault_snapshot[vl_status_idx[2:0]] <= 1'b1;
            else
                vl_fault_snapshot[vl_status_idx[2:0]] <= 1'b0;
            vl_status_idx <= (vl_status_idx == 12'd7) ? 12'd0
                                                      : vl_status_idx + 12'd1;
            vl_status_req <= 1'b0;
        end else if (!vl_status_req) begin
            vl_status_req <= 1'b1;
        end
    end

    afdx_snmp_agent u_agent (
        .clk(clk), .reset(reset),
        .sys_uptime(sys_uptime), .cnt_tx_frames(cnt_tx_frames),
        .cnt_rx_frames(cnt_rx_frames), .cnt_rx_errors(cnt_rx_errors),
        .cnt_dup(cnt_dup), .cnt_ic_err(cnt_ic_err),
        .vl_fault(vl_fault_snapshot), .vl_capacity(vl_capacity),
        .req_wr(snmp_wr), .req_data(req_data), .req_last(snmp_last),
        .req_start(snmp_start),
        .resp_valid(resp_valid), .resp_data(resp_data), .resp_last(resp_last),
        .resp_begin(resp_begin),
        .req_cnt(snmp_req_cnt), .resp_cnt(snmp_resp_cnt),
        .drop_cnt(snmp_drop_cnt), .no_such_cnt(snmp_nosuch_cnt),
        .trap_valid(trap_valid), .trap_data(trap_data), .trap_last(trap_last),
        .trap_begin(trap_begin), .trap_cnt(trap_cnt)
    );

    // ---------------- ARINC 615A 加载器 ----------------
    wire        load_resp_valid, load_resp_last, load_resp_begin;
    wire [7:0]  load_resp_data;
    wire [15:0] load_img_len, load_req_cnt, load_err_cnt;
    wire [31:0] load_img_crc;
    wire        load_loaded;

    afdx_load_615a #(.IMG_BYTES(1024)) u_load (
        .clk(clk), .reset(reset),
        .msg_wr(load_wr), .msg_data(req_data), .msg_last(load_last),
        .msg_start(load_start),
        .img_len(load_img_len), .img_crc(load_img_crc), .loaded(load_loaded),
        .req_cnt(load_req_cnt), .err_cnt(load_err_cnt),
        .resp_valid(load_resp_valid), .resp_data(load_resp_data),
        .resp_last(load_resp_last), .resp_begin(load_resp_begin)
    );

    // ---------------- RTC 时间同步 ----------------
    wire        rtc_resp_valid, rtc_resp_last, rtc_resp_begin;
    wire [7:0]  rtc_resp_data;
    wire [31:0] rtc_sec, rtc_nsec;
    wire        rtc_synced;
    wire [15:0] rtc_sync_cnt;

    afdx_rtc_sync u_rtc (
        .clk(clk), .reset(reset),
        .msg_wr(rtc_wr), .msg_data(req_data), .msg_last(rtc_last),
        .msg_start(rtc_start),
        .rtc_sec(rtc_sec), .rtc_nsec(rtc_nsec), .synced(rtc_synced),
        .sync_cnt(rtc_sync_cnt),
        .resp_valid(rtc_resp_valid), .resp_data(rtc_resp_data),
        .resp_last(rtc_resp_last), .resp_begin(rtc_resp_begin)
    );

    // 响应与 Trap 共用发送封装（Trap 优先；引擎由 sel_engine 选择）
    wire       snmp_sel = (sel_engine == 2'd0);
    wire [7:0] eng_data = snmp_sel ? resp_data :
                          (sel_engine == 2'd1) ? load_resp_data : rtc_resp_data;
    wire       eng_valid = snmp_sel ? resp_valid :
                           (sel_engine == 2'd1) ? load_resp_valid : rtc_resp_valid;
    wire       eng_last  = snmp_sel ? resp_last :
                           (sel_engine == 2'd1) ? load_resp_last : rtc_resp_last;

    wire       pkt_valid = trap_valid | eng_valid;
    wire [7:0] pkt_data  = trap_valid ? trap_data : eng_data;
    wire       pkt_last  = trap_valid ? trap_last : eng_last;

    // =========================================================================
    // 接收：帧缓存与端口 161 分流
    // =========================================================================
    // 2048 字节接收帧缓存拆为双 bank，各自使用独立输出寄存器。
    // 读口地址由 R_START/R_FEED 预取，综合器可推断为简单双口 RAM。
    localparam MEM_BANK_BYTES = 1024;
    localparam HDR_BYTES      = 42;
    (* ramstyle = "M4K", no_rw_check *) reg [7:0] mem_lo [0:MEM_BANK_BYTES-1];
    (* ramstyle = "M4K", no_rw_check *) reg [7:0] mem_hi [0:MEM_BANK_BYTES-1];
    reg [7:0]  mem_hdr [0:HDR_BYTES-1];
    reg [7:0]  mem_lo_q, mem_hi_q;
    reg        mem_bank_q;
    reg [15:0] mem_raddr;
    wire [7:0] mem_rdata = mem_bank_q ? mem_hi_q : mem_lo_q;
    reg [11:0] wrp;
    reg        in_frame;
    reg [15:0] f_len;
    reg        frame_pend;

    reg [47:0] req_src_mac;
    reg [31:0] req_src_ip;
    reg [15:0] req_src_port;
    reg [15:0] payload_len;

    localparam [2:0] R_IDLE = 3'd0, R_CHK = 3'd1, R_START = 3'd2,
                     R_FEED = 3'd3, R_WAIT = 3'd4;
    reg [2:0]  rst;
    reg [10:0] feed_i;

    wire [15:0] udp_len_w = {mem_hdr[38], mem_hdr[39]};
    wire [15:0] pay_len_w = udp_len_w - 16'd8;
    wire [15:0] iplen_w   = {mem_hdr[16], mem_hdr[17]};

    wire [15:0] dport_w = {mem_hdr[36], mem_hdr[37]};
    wire is_snmp_port = (dport_w == UDP_PORT);
    wire is_load_port = (dport_w == 16'd10000);
    wire is_rtc_port  = (dport_w == 16'd123);

    wire is_mgmt = frame_pend && (f_len >= 16'd60) &&
                   ({mem_hdr[12], mem_hdr[13]} == `ETH_TYPE_IPV4) &&
                   (mem_hdr[14] == 8'h45) && (mem_hdr[23] == `IPV4_PROTO_UDP) &&
                   (is_snmp_port || is_load_port || is_rtc_port) &&
                   (udp_len_w >= 16'd9) &&
                   (iplen_w == (udp_len_w + 16'd20)) &&
                   ((udp_len_w + 16'd38) <= f_len);

    reg resp_seen;

    // 仅在请求馈送阶段读缓存；状态切换时提前给出下一字节地址。
    always @(*) begin
        mem_raddr = 16'd0;
        case (rst)
            R_START: mem_raddr = 16'd42;
            R_FEED: begin
                if ((feed_i + 11'd1) < payload_len[10:0])
                    mem_raddr = 16'd43 + feed_i;
                else
                    mem_raddr = 16'd42 + feed_i;
            end
            default: mem_raddr = 16'd0;
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            wrp        <= 12'd0;
            in_frame   <= 1'b0;
            f_len      <= 16'd0;
            frame_pend <= 1'b0;
        end else begin
            if (rst == R_IDLE) begin
                if (rx_valid) begin
                    if (wrp < 2048) begin
                        if (wrp[10])
                            mem_hi[wrp[9:0]] <= rx_data;
                        else
                            mem_lo[wrp[9:0]] <= rx_data;
                    end
                    if (wrp < HDR_BYTES)
                        mem_hdr[wrp[5:0]] <= rx_data;
                    wrp      <= wrp + 12'd1;
                    in_frame <= 1'b1;
                end else if (in_frame) begin
                    f_len      <= wrp;
                    in_frame   <= 1'b0;
                    frame_pend <= 1'b1;
                    wrp        <= 12'd0;
                end
            end
            if (rst == R_WAIT)
                frame_pend <= 1'b0;

            mem_lo_q   <= mem_lo[mem_raddr[9:0]];
            mem_hi_q   <= mem_hi[mem_raddr[9:0]];
            mem_bank_q <= mem_raddr[10];
        end
    end

    // =========================================================================
    // 发送：响应缓存 + UDP/IP 封装
    // =========================================================================
    (* ramstyle = "M4K", no_rw_check *) reg [7:0] pmem [0:511];
    reg [8:0]  pmem_raddr;
    reg [7:0]  pmem_q;
    reg [9:0]  pwptr;
    reg [15:0] plen;

    reg [7:0]  mhdr [0:41];
    reg [15:0] pad_n;
    reg [31:0] fcs_q;
    reg [15:0] k;

    reg         ck_init, ck_en, ck_fin, ck_udp;
    wire [7:0]  ck_din;
    wire [15:0] ck_sum;
    wire        ck_ok;

    afdx_checksum16 u_ck (
        .clk(clk), .reset(reset), .init(ck_init), .en(ck_en), .din(ck_din),
        .finalize(ck_fin), .udp_zero_to_ones(ck_udp),
        .checksum(ck_sum), .valid(ck_ok)
    );

    reg         crc_init, crc_en;
    wire [7:0]  crc_din;
    wire [31:0] crc_fcs;

    afdx_crc32 u_crc (
        .clk(clk), .reset(reset), .init(crc_init), .en(crc_en),
        .din(crc_din), .crc(), .fcs(crc_fcs)
    );

    localparam [4:0] T_IDLE = 5'd0,  T_HDR  = 5'd1,
                     T_IP_I = 5'd2,  T_IP_F = 5'd3,  T_IP_L = 5'd4,  T_IP_W = 5'd5,
                     T_UD_I = 5'd6,  T_UD_P = 5'd7,  T_UD_H = 5'd8,  T_UD_F = 5'd9,
                     T_UD_L = 5'd10, T_UD_W = 5'd11,
                     T_CR_I = 5'd12, T_CR_F = 5'd13, T_CR_L = 5'd14,
                     T_WAIT = 5'd15, T_SEND = 5'd16, T_IFG  = 5'd17;
    reg [4:0]  tst;
    reg [3:0]  ps_i;

    wire [15:0] ip_len_w  = plen + 16'd28;                 // 20 + 8 + payload
    wire [15:0] ud_len_w  = plen + 16'd8;
    wire [15:0] body_len  = 16'd42 + plen + pad_n;         // 不含 FCS
    wire [15:0] total_len = body_len + 16'd4;
    wire [15:0] fcs_i     = k - body_len;

    // 发送封装缓存同步读：UDP 校验和、CRC 预计算和最终发送分阶段预取。
    always @(*) begin
        pmem_raddr = 9'd0;
        case (tst)
            T_UD_H: begin
                // 进入 UDP 载荷校验前预取 pmem[0]。
                if (k == 16'd7) pmem_raddr = 9'd0;
            end
            T_UD_F: begin
                if ((k + 16'd1) < plen) pmem_raddr = k[8:0] + 9'd1;
            end
            T_CR_F: begin
                if (k == 16'd41)
                    pmem_raddr = 9'd0;
                else if ((k > 16'd41) && ((k - 16'd41) < plen))
                    pmem_raddr = k[8:0] - 9'd41;
            end
            T_WAIT, T_SEND: begin
                if (k == 16'd41)
                    pmem_raddr = 9'd0;
                else if ((k > 16'd41) && ((k - 16'd41) < plen))
                    pmem_raddr = k[8:0] - 16'd41;
            end
            default: pmem_raddr = 9'd0;
        endcase
    end

    reg [7:0] body_b;
    always @(*) begin
        if (k < 16'd42)          body_b = mhdr[k[5:0]];
        else if (k < (16'd42 + plen)) body_b = pmem_q;
        else                     body_b = 8'h00;
    end

    reg [7:0] fcs_b;
    always @(*) begin
        case (fcs_i[1:0])
            2'd0:    fcs_b = fcs_q[7:0];
            2'd1:    fcs_b = fcs_q[15:8];
            2'd2:    fcs_b = fcs_q[23:16];
            default: fcs_b = fcs_q[31:24];
        endcase
    end

    assign tx_data = (k < body_len) ? body_b : fcs_b;
    assign tx_busy = (tst != T_IDLE) || (rst == R_FEED);

    reg [7:0] pseudo_b;
    always @(*) begin
        case (ps_i)
            4'd0:    pseudo_b = ES_IP[31:24];
            4'd1:    pseudo_b = ES_IP[23:16];
            4'd2:    pseudo_b = ES_IP[15:8];
            4'd3:    pseudo_b = ES_IP[7:0];
            4'd4:    pseudo_b = req_src_ip[31:24];
            4'd5:    pseudo_b = req_src_ip[23:16];
            4'd6:    pseudo_b = req_src_ip[15:8];
            4'd7:    pseudo_b = req_src_ip[7:0];
            4'd8:    pseudo_b = 8'h00;
            4'd9:    pseudo_b = `IPV4_PROTO_UDP;
            4'd10:   pseudo_b = ud_len_w[15:8];
            default: pseudo_b = ud_len_w[7:0];
        endcase
    end

    assign ck_din = (tst == T_UD_P) ? pseudo_b :
                    (tst == T_UD_H) ? ((k < 16'd6) ? mhdr[6'd34 + k[5:0]] : 8'h00) :
                    (tst == T_UD_F) ? pmem_q : mhdr[6'd14 + k[5:0]];

    assign crc_din = body_b;

    // =========================================================================
    // 主状态机
    // =========================================================================
    integer i;

    always @(posedge clk) begin
        if (reset) begin
            rst        <= R_IDLE;
            tst        <= T_IDLE;
            feed_i     <= 11'd0;
            req_wr     <= 1'b0;
            req_last   <= 1'b0;
            req_start  <= 1'b0;
            req_data   <= 8'd0;
            pwptr      <= 10'd0;
            plen       <= 16'd0;
            tx_valid   <= 1'b0;
            k          <= 16'd0;
            ps_i       <= 4'd0;
            ck_init <= 1'b0; ck_en <= 1'b0; ck_fin <= 1'b0; ck_udp <= 1'b0;
            crc_init <= 1'b0; crc_en <= 1'b0;
            fcs_q <= 32'd0;
            payload_len <= 16'd0;
            req_src_mac <= 48'h0; req_src_ip <= 32'h0; req_src_port <= 16'h0;
            pad_n <= 16'd0;
            for (i = 0; i < 42; i = i + 1) mhdr[i] <= 8'h00;
        end else begin
            req_wr    <= 1'b0;
            req_last  <= 1'b0;
            req_start <= 1'b0;
            tx_valid  <= 1'b0;
            ck_init   <= 1'b0;
            ck_en     <= 1'b0;
            ck_fin    <= 1'b0;
            crc_init  <= 1'b0;
            crc_en    <= 1'b0;

            // ---------------- 接收侧 ----------------
            case (rst)
            R_IDLE: begin
                if (frame_pend) rst <= R_CHK;
            end
            R_CHK: begin
                if (is_mgmt && (tst == T_IDLE)) begin
                    req_src_mac  <= {mem_hdr[6], mem_hdr[7], mem_hdr[8],
                                     mem_hdr[9], mem_hdr[10], mem_hdr[11]};
                    req_src_ip   <= {mem_hdr[26], mem_hdr[27],
                                     mem_hdr[28], mem_hdr[29]};
                    req_src_port <= {mem_hdr[34], mem_hdr[35]};
                    payload_len  <= pay_len_w;
                    feed_i       <= 11'd0;
                    sel_engine   <= is_load_port ? 2'd1 : (is_rtc_port ? 2'd2 : 2'd0);
                    rst          <= R_START;
                end else begin
                    rst <= R_WAIT;
                end
            end
            R_START: begin
                req_start <= 1'b1;      // 先清写指针，下一拍再写首字节
                resp_seen <= 1'b0;
                rst       <= R_FEED;
            end
            R_FEED: begin
                req_wr   <= 1'b1;
                req_data <= mem_rdata;
                req_last <= (feed_i == (payload_len - 16'd1));
                if (feed_i == (payload_len - 16'd1))
                    rst <= R_WAIT;
                else
                    feed_i <= feed_i + 11'd1;
            end
            R_WAIT: begin
                if (resp_seen && (tst == T_IDLE)) rst <= R_IDLE;
            end
            default: rst <= R_IDLE;
            endcase

            // ---------------- 响应缓存（仅在发送空闲时接收） ----------------
            if (pkt_valid && (tst == T_IDLE)) begin
                pmem[pwptr] <= pkt_data;
                pwptr       <= pwptr + 10'd1;
                if (pkt_last) begin
                    resp_seen <= 1'b1;
                    plen  <= {6'h0, pwptr} + 16'd1;
                    tst   <= T_HDR;
                    pwptr <= 10'd0;
                end
            end

            // ---------------- 发送侧 ----------------
            case (tst)
            T_IDLE: ;                    // 必须显式列出：否则 default 会覆盖响应结束时的 T_HDR 跳转

            T_HDR: begin
                mhdr[0]  <= req_src_mac[47:40]; mhdr[1]  <= req_src_mac[39:32];
                mhdr[2]  <= req_src_mac[31:24]; mhdr[3]  <= req_src_mac[23:16];
                mhdr[4]  <= req_src_mac[15:8];  mhdr[5]  <= req_src_mac[7:0];
                mhdr[6]  <= ES_MAC[47:40];      mhdr[7]  <= ES_MAC[39:32];
                mhdr[8]  <= ES_MAC[31:24];      mhdr[9]  <= ES_MAC[23:16];
                mhdr[10] <= ES_MAC[15:8];       mhdr[11] <= ES_MAC[7:0];
                mhdr[12] <= `ETH_TYPE_IPV4_HI;  mhdr[13] <= `ETH_TYPE_IPV4_LO;
                mhdr[14] <= 8'h45;              mhdr[15] <= 8'h00;
                mhdr[16] <= ip_len_w[15:8];     mhdr[17] <= ip_len_w[7:0];
                mhdr[18] <= 8'h00;              mhdr[19] <= 8'h00;
                mhdr[20] <= 8'h00;              mhdr[21] <= 8'h00;
                mhdr[22] <= TTL;                mhdr[23] <= `IPV4_PROTO_UDP;
                mhdr[24] <= 8'h00;              mhdr[25] <= 8'h00;
                mhdr[26] <= ES_IP[31:24];       mhdr[27] <= ES_IP[23:16];
                mhdr[28] <= ES_IP[15:8];        mhdr[29] <= ES_IP[7:0];
                mhdr[30] <= req_src_ip[31:24];  mhdr[31] <= req_src_ip[23:16];
                mhdr[32] <= req_src_ip[15:8];   mhdr[33] <= req_src_ip[7:0];
                mhdr[34] <= UDP_PORT[15:8];     mhdr[35] <= UDP_PORT[7:0];
                mhdr[36] <= req_src_port[15:8]; mhdr[37] <= req_src_port[7:0];
                mhdr[38] <= ud_len_w[15:8];     mhdr[39] <= ud_len_w[7:0];
                mhdr[40] <= 8'h00;              mhdr[41] <= 8'h00;

                pad_n <= ((16'd42 + plen) < 16'd60) ? (16'd60 - 16'd42 - plen) : 16'd0;
                k     <= 16'd0;
                tst   <= T_IP_I;
            end

            T_IP_I: begin ck_init <= 1'b1; ck_udp <= 1'b0; k <= 16'd0; tst <= T_IP_F; end
            T_IP_F: begin
                ck_en <= 1'b1;
                if (k == 16'd19) begin k <= 16'd0; tst <= T_IP_L; end
                else                  k <= k + 16'd1;
            end
            T_IP_L: begin ck_en <= 1'b0; ck_fin <= 1'b1; tst <= T_IP_W; end
            T_IP_W: begin
                mhdr[24] <= ck_sum[15:8];
                mhdr[25] <= ck_sum[7:0];
                k        <= 16'd0;
                ps_i     <= 4'd0;
                tst      <= T_UD_I;
            end

            T_UD_I: begin ck_init <= 1'b1; ck_udp <= 1'b1; ps_i <= 4'd0; tst <= T_UD_P; end
            T_UD_P: begin
                ck_en <= 1'b1;
                if (ps_i == 4'd11) begin ps_i <= 4'd0; k <= 16'd0; tst <= T_UD_H; end
                else                     ps_i <= ps_i + 4'd1;
            end
            T_UD_H: begin
                ck_en <= 1'b1;
                if (k == 16'd7) begin k <= 16'd0; tst <= T_UD_F; end
                else                 k <= k + 16'd1;
            end
            T_UD_F: begin
                ck_en <= 1'b1;
                if (k == (plen - 16'd1)) begin k <= 16'd0; tst <= T_UD_L; end
                else                          k <= k + 16'd1;
            end
            T_UD_L: begin ck_en <= 1'b0; ck_fin <= 1'b1; tst <= T_UD_W; end
            T_UD_W: begin
                mhdr[40] <= ck_sum[15:8];
                mhdr[41] <= ck_sum[7:0];
                k        <= 16'd0;
                tst      <= T_CR_I;
            end

            T_CR_I: begin crc_init <= 1'b1; k <= 16'd0; tst <= T_CR_F; end
            T_CR_F: begin
                crc_en <= 1'b1;
                if (k == (body_len - 16'd1)) tst <= T_CR_L;
                else                         k   <= k + 16'd1;
            end
            T_CR_L: begin
                fcs_q <= crc_fcs;
                k     <= 16'd0;
                tst   <= T_WAIT;
            end

            T_WAIT: begin
                // 提前一拍置 valid：保证进入 T_SEND 的第一拍就发出 k=0 的字节
                if (tx_free) begin
                    tx_valid <= 1'b1;
                    tst      <= T_SEND;
                end
            end

            T_SEND: begin
                tx_valid <= 1'b1;
                if (k == (total_len - 16'd1)) begin
                    k   <= 16'd0;
                    tst <= T_IFG;
                end else begin
                    k <= k + 16'd1;
                end
            end

            T_IFG: tst <= T_IDLE;

            default: tst <= T_IDLE;
            endcase

            pmem_q <= pmem[pmem_raddr];
        end
    end

endmodule
