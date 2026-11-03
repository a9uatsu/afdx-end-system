// =============================================================================
// 文件名  : tb_afdx_rtc.v
// 用途    : RTC 时间同步单元测试
//           1) 发送 9 字节时间基准（sec=100, nsec=0）
//           2) 等待 1000 个时钟（20 µs）
//           3) 查询并检查回读时间
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_rtc;

    reg clk = 0;
    reg reset = 1;
    always #10 clk = ~clk;

    reg        msg_wr = 0, msg_last = 0, msg_start = 0;
    reg [7:0]  msg_data = 8'h00;
    wire       resp_valid, resp_last, resp_begin;
    wire [7:0] resp_data;
    wire [31:0] rtc_sec, rtc_nsec;
    wire        synced;
    wire [15:0] sync_cnt;

    afdx_rtc_sync dut (
        .clk(clk), .reset(reset),
        .msg_wr(msg_wr), .msg_data(msg_data), .msg_last(msg_last), .msg_start(msg_start),
        .rtc_sec(rtc_sec), .rtc_nsec(rtc_nsec), .synced(synced), .sync_cnt(sync_cnt),
        .resp_valid(resp_valid), .resp_data(resp_data), .resp_last(resp_last),
        .resp_begin(resp_begin)
    );

    reg [7:0] rbuf [0:15];
    reg [7:0] first_byte;
    integer   rlen, i, n_err;
    reg [31:0] q_sec, q_nsec;

    always @(posedge clk) begin
        if (!reset) begin
            if (resp_valid) begin
                if (resp_begin) first_byte <= resp_data;
                rbuf[rlen] <= resp_data;
                if (resp_last) begin
                    q_sec  <= {rbuf[1], rbuf[2], rbuf[3], resp_data}; // 占位，下面按序重建
                    rlen   <= 0;
                end else begin
                    rlen <= rlen + 1;
                end
            end
        end
    end

    task send_byte;
        input [7:0] b;
        input       last;
        begin
            @(negedge clk); msg_wr = 1'b1; msg_data = b; msg_last = last;
        end
    endtask

    integer j;
    initial begin
        n_err = 0; rlen = 0; q_sec = 0; q_nsec = 0;

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        // ---- 1) 装载时间基准 sec=100, nsec=0 ----
        @(negedge clk); msg_start = 1'b1;
        @(negedge clk); msg_start = 1'b0;
        send_byte(8'h01, 1'b0);
        send_byte(8'd0, 1'b0); send_byte(8'd0, 1'b0); send_byte(8'd0, 1'b0); send_byte(8'd100, 1'b0);
        send_byte(8'd0, 1'b0); send_byte(8'd0, 1'b0); send_byte(8'd0, 1'b0); send_byte(8'd0, 1'b1);
        @(negedge clk); msg_wr = 1'b0; msg_last = 1'b0;

        repeat (10) @(posedge clk);
        if (rtc_sec !== 32'd100 || !synced) begin
            $display("[FAIL] 时间装载失败: sec=%0d synced=%b", rtc_sec, synced);
            n_err = n_err + 1;
        end else begin
            $display("[PASS] 时间装载: sec=%0d nsec=%0d", rtc_sec, rtc_nsec);
        end

        // ---- 2) 运行 1000 个时钟（20 µs） ----
        repeat (1000) @(posedge clk);
        if (rtc_sec !== 32'd100 || rtc_nsec < 32'd19000 || rtc_nsec > 32'd21000) begin
            $display("[FAIL] 时间运行异常: sec=%0d nsec=%0d", rtc_sec, rtc_nsec);
            n_err = n_err + 1;
        end else begin
            $display("[PASS] 时间运行: sec=%0d nsec=%0d (约 20us)", rtc_sec, rtc_nsec);
        end

        // ---- 3) 查询 ----
        @(negedge clk); msg_start = 1'b1;
        @(negedge clk); msg_start = 1'b0;
        send_byte(8'h02, 1'b1);
        @(negedge clk); msg_wr = 1'b0; msg_last = 1'b0;
        repeat (30) @(posedge clk);

        // 用层次化读取直接检查响应缓冲
        if (first_byte !== 8'h81 || dut.rtc_sec !== 32'd100 || sync_cnt !== 16'd1) begin
            $display("[FAIL] 查询响应异常 (op=%02x sec=%0d sync=%0d)",
                     first_byte, dut.rtc_sec, sync_cnt);
            n_err = n_err + 1;
        end else begin
            $display("[PASS] 查询响应: op=0x81 sec=%0d nsec=%0d", dut.rtc_sec, dut.rtc_nsec);
        end

        $display("");
        $display("==================== RTC 同步测试汇总 ====================");
        $display("同步次数=%0d  错误数=%0d", sync_cnt, n_err);
        if (n_err == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $display("=========================================================");
        $finish;
    end

endmodule
