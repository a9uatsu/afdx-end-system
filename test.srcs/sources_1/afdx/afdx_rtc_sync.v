// =============================================================================
// 文件名  : afdx_rtc_sync.v
// 模块    : afdx_rtc_sync
// 功能    : RTC 时间同步（简化 SNTP 风格）
//           本地时基：50 MHz，每周期 20 ns
//           请求（UDP 载荷 9 字节）：
//             [0x01][sec(4B BE)][nsec(4B BE)] -> 装载时间基准
//             [0x02]                          -> 查询（只要求首字节）
//           响应（9 字节）：[0x81][sec(4B)][nsec(4B)]
//           说明：仅做"基准装载 + 自由运行 + 回读"，未实现往返时延补偿。
// =============================================================================
`include "afdx_defs.vh"

module afdx_rtc_sync (
    input  wire        clk,
    input  wire        reset,
    // ---- 报文写入 ----
    input  wire        msg_wr,
    input  wire [7:0]  msg_data,
    input  wire        msg_last,
    input  wire        msg_start,
    // ---- 时间 ----
    output reg  [31:0] rtc_sec,
    output reg  [31:0] rtc_nsec,
    output reg         synced,
    output reg  [15:0] sync_cnt,
    // ---- 响应流 ----
    output reg         resp_valid,
    output reg  [7:0]  resp_data,
    output reg         resp_last,
    output reg         resp_begin
);

    localparam [31:0] NS_PER_SEC = 32'd1_000_000_000;
    localparam [31:0] NS_STEP    = 32'd20;          // 50 MHz

    // ---------------- 先声明跨块使用的信号 ----------------
    reg        load_en;
    reg [31:0] load_sec, load_nsec;
    reg        query_pulse;
    reg [7:0]  mbuf [0:8];
    reg [3:0]  mwr;
    reg        parse;
    reg [7:0]  opcode;

    // ---------------- 时间运行 ----------------
    always @(posedge clk) begin
        if (reset) begin
            rtc_sec  <= 32'd0;
            rtc_nsec <= 32'd0;
            synced   <= 1'b0;
        end else if (load_en) begin
            rtc_sec  <= load_sec;
            rtc_nsec <= load_nsec;
            synced   <= 1'b1;
        end else if ((rtc_nsec + NS_STEP) >= NS_PER_SEC) begin
            rtc_nsec <= rtc_nsec + NS_STEP - NS_PER_SEC;
            rtc_sec  <= rtc_sec + 32'd1;
        end else begin
            rtc_nsec <= rtc_nsec + NS_STEP;
        end
    end

    // ---------------- 报文解析 ----------------
    always @(posedge clk) begin
        if (reset) begin
            mwr         <= 4'd0;
            parse       <= 1'b0;
            load_en     <= 1'b0;
            query_pulse <= 1'b0;
            load_sec    <= 32'd0;
            load_nsec   <= 32'd0;
            opcode      <= 8'd0;
            sync_cnt    <= 16'd0;
        end else begin
            load_en <= 1'b0;
            query_pulse <= 1'b0;

            if (msg_start) begin
                mwr   <= 4'd0;
                parse <= 1'b0;
            end else if (msg_wr) begin
                if (mwr < 9) mbuf[mwr] <= msg_data;
                mwr <= mwr + 4'd1;
                if (msg_last) parse <= 1'b1;
            end

            if (parse) begin
                parse  <= 1'b0;
                opcode <= mbuf[0];
                if (mbuf[0] == 8'h01) begin
                    load_sec  <= {mbuf[1], mbuf[2], mbuf[3], mbuf[4]};
                    load_nsec <= {mbuf[5], mbuf[6], mbuf[7], mbuf[8]};
                    load_en   <= 1'b1;
                    sync_cnt  <= sync_cnt + 16'd1;
                end else if (mbuf[0] == 8'h02) begin
                    query_pulse <= 1'b1;
                end
            end
        end
    end

    // ---------------- 响应组包 ----------------
    reg [8:0] rp;
    reg       sending;

    always @(posedge clk) begin
        if (reset) begin
            sending    <= 1'b0;
            rp         <= 9'd0;
            resp_valid <= 1'b0;
            resp_last  <= 1'b0;
            resp_begin <= 1'b0;
            resp_data  <= 8'd0;
        end else begin
            resp_valid <= 1'b0;
            resp_last  <= 1'b0;
            resp_begin <= 1'b0;

            if (query_pulse && !sending) begin
                sending     <= 1'b1;
                rp          <= 9'd0;
            end

            if (sending) begin
                resp_valid <= 1'b1;
                resp_begin <= (rp == 9'd0);
                resp_last  <= (rp == 9'd8);
                case (rp)
                    9'd0:    resp_data <= 8'h81;
                    9'd1:    resp_data <= rtc_sec[31:24];
                    9'd2:    resp_data <= rtc_sec[23:16];
                    9'd3:    resp_data <= rtc_sec[15:8];
                    9'd4:    resp_data <= rtc_sec[7:0];
                    9'd5:    resp_data <= rtc_nsec[31:24];
                    9'd6:    resp_data <= rtc_nsec[23:16];
                    9'd7:    resp_data <= rtc_nsec[15:8];
                    default: resp_data <= rtc_nsec[7:0];
                endcase
                if (rp == 9'd8) sending <= 1'b0;
                rp <= rp + 9'd1;
            end
        end
    end

endmodule
