// =============================================================================
// 文件名  : afdx_load_615a.v
// 模块    : afdx_load_615a
// 功能    : ARINC 615A 风格的数据加卸载（简化子集，UDP 载荷接口）
//
// 报文（UDP 载荷，首字节为操作码）：
//   0x01 WRQ     : [01][len_hi][len_lo][filename...]  -> 复位镜像与 CRC
//   0x02 DATA    : [02][blk_hi][blk_lo][data<=512]    -> 写入 (blk-1)*512，更新 CRC
//   0x03 ACTIVATE: [03]                               -> 锁存 CRC，标记加载完成
//   0x04 READ    : [04]                               -> 回读长度与 CRC
// 响应固定 8 字节：[op|0x80][status][arg_hi][arg_lo][crc32(4)]
// 镜像容量：8 KB（16 × 512 字节块）
// 说明：可演示的数据加卸载子集，未实现完整 615A 会话/文件系统语义。
// =============================================================================
`include "afdx_defs.vh"

module afdx_load_615a #(
    parameter IMG_BYTES = 1024
) (
    input  wire        clk,
    input  wire        reset,
    // ---- 报文写入 ----
    input  wire        msg_wr,
    input  wire [7:0]  msg_data,
    input  wire        msg_last,
    input  wire        msg_start,
    // ---- 状态 ----
    output reg  [15:0] img_len,
    output reg  [31:0] img_crc,
    output reg         loaded,
    output reg  [15:0] req_cnt,
    output reg  [15:0] err_cnt,
    // ---- 响应流 ----
    output reg         resp_valid,
    output reg  [7:0]  resp_data,
    output reg         resp_last,
    output reg         resp_begin
);

    // ---------------- 镜像 RAM 与消息缓冲 ----------------
    reg [7:0]  img  [0:IMG_BYTES-1];
    reg [7:0]  mbuf [0:519];
    reg [10:0] mwr;
    reg        parse;

    reg [7:0]  opcode;
    reg [15:0] dlen;
    reg [15:0] blk;
    reg [15:0] wr_base;
    reg [10:0] wi;

    // ---------------- CRC（写入时增量计算） ----------------
    reg        crc_init, crc_en;
    reg [7:0]  crc_din;
    wire [31:0] crc_fcs;

    afdx_crc32 u_crc (
        .clk(clk), .reset(reset), .init(crc_init), .en(crc_en),
        .din(crc_din), .crc(), .fcs(crc_fcs)
    );

    // ---------------- 响应 ----------------
    reg [3:0]  rp;
    reg        sending;
    reg        resp_pending;
    reg [7:0]  rbyte [0:7];
    reg [7:0]  status;

    // 状态码（组合）：0=OK, 1=DATA 报文过短, 2=未知操作码
    wire [7:0] status_w = (mbuf[0] == 8'h02 && mwr < 4) ? 8'd1 :
                          ((mbuf[0] == 8'h01) || (mbuf[0] == 8'h02) ||
                           (mbuf[0] == 8'h03) || (mbuf[0] == 8'h04)) ? 8'd0 : 8'd2;

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            opcode     <= 8'd0;
            dlen       <= 16'd0;
            blk        <= 16'd0;
            wr_base    <= 16'd0;
            wi         <= 11'd0;
            img_len    <= 16'd0;
            img_crc    <= 32'd0;
            loaded     <= 1'b0;
            req_cnt    <= 16'd0;
            err_cnt    <= 16'd0;
            crc_init   <= 1'b0;
            crc_en     <= 1'b0;
            crc_din    <= 8'd0;
            sending    <= 1'b0;
            resp_pending <= 1'b0;
            rp         <= 4'd0;
            resp_valid <= 1'b0;
            resp_data  <= 8'd0;
            resp_last  <= 1'b0;
            resp_begin <= 1'b0;
            status     <= 8'd0;
            mwr        <= 11'd0;
            parse      <= 1'b0;
            for (i = 0; i < 8; i = i + 1) rbyte[i] <= 8'h00;
        end else begin
            crc_init   <= 1'b0;
            crc_en     <= 1'b0;
            resp_valid <= 1'b0;
            resp_last  <= 1'b0;
            resp_begin <= 1'b0;

            // ---------------- 消息接收（与本模块同一时序块，保证单驱动） ----------------
            if (msg_start) begin
                mwr   <= 11'd0;
                parse <= 1'b0;
            end else if (msg_wr) begin
                if (mwr < 520) mbuf[mwr] <= msg_data;
                mwr <= mwr + 11'd1;
                if (msg_last) parse <= 1'b1;
            end

            // ---------------- 解析并准备响应 ----------------
            if (parse) begin
                parse   <= 1'b0;
                req_cnt <= req_cnt + 16'd1;
                opcode  <= mbuf[0];
                status  <= 8'd0;
                rbyte[0] <= mbuf[0] | 8'h80;
                rbyte[2] <= 8'h00;
                rbyte[3] <= 8'h00;
                rbyte[4] <= 8'h00;
                rbyte[5] <= 8'h00;
                rbyte[6] <= 8'h00;
                rbyte[7] <= 8'h00;

                case (mbuf[0])
                8'h01: begin                       // WRQ
                    img_len  <= 16'd0;
                    img_crc  <= 32'd0;
                    loaded   <= 1'b0;
                    blk      <= 16'd0;
                    crc_init <= 1'b1;
                    resp_pending <= 1'b1;
                end
                8'h02: begin                       // DATA
                    blk     <= {mbuf[1], mbuf[2]};
                    dlen    <= {5'h00, mwr} - 16'd3;
                    wr_base <= ({mbuf[1], mbuf[2]} - 16'd1) * 16'd512;
                    wi      <= 11'd0;
                    rbyte[2] <= mbuf[1];
                    rbyte[3] <= mbuf[2];
                    if (mwr < 4) begin
                        err_cnt <= err_cnt + 16'd1;
                        status  <= 8'd1;
                    end
                    resp_pending <= 1'b1;
                end
                8'h03: begin                       // ACTIVATE
                    img_crc <= crc_fcs;
                    loaded  <= 1'b1;
                    rbyte[4] <= crc_fcs[31:24];
                    rbyte[5] <= crc_fcs[23:16];
                    rbyte[6] <= crc_fcs[15:8];
                    rbyte[7] <= crc_fcs[7:0];
                    resp_pending <= 1'b1;
                end
                8'h04: begin                       // READ
                    rbyte[2] <= img_len[15:8];
                    rbyte[3] <= img_len[7:0];
                    rbyte[4] <= img_crc[31:24];
                    rbyte[5] <= img_crc[23:16];
                    rbyte[6] <= img_crc[15:8];
                    rbyte[7] <= img_crc[7:0];
                    resp_pending <= 1'b1;
                end
                default: begin
                    err_cnt <= err_cnt + 16'd1;
                    status  <= 8'd2;
                    resp_pending <= 1'b1;
                end
                endcase
                rbyte[1] <= status_w;
            end

            // ---------------- DATA 字节写入 ----------------
            if ((opcode == 8'h02) && (wi < dlen)) begin
                if ((wr_base + wi) < IMG_BYTES) begin
                    img[wr_base + wi] <= mbuf[3 + wi];
                    crc_en  <= 1'b1;
                    crc_din <= mbuf[3 + wi];
                end
                wi <= wi + 11'd1;
                if ((wr_base + wi + 16'd1) > img_len)
                    img_len <= wr_base + wi + 16'd1;
            end

            // ---------------- 响应启动 ----------------
            // DATA 需等字节写完再响应；其它操作立即响应
            if (resp_pending && !sending && ((opcode != 8'h02) || (wi >= dlen))) begin
                resp_pending <= 1'b0;
                sending      <= 1'b1;
                rp           <= 4'd0;
            end

            // ---------------- 响应流出 ----------------
            if (sending) begin
                resp_valid <= 1'b1;
                resp_data  <= rbyte[rp];
                resp_begin <= (rp == 4'd0);
                resp_last  <= (rp == 4'd7);
                if (rp == 4'd7) sending <= 1'b0;
                rp <= rp + 4'd1;
            end
        end
    end

endmodule
