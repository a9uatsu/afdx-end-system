// =============================================================================
// 文件名  : tb_afdx_perf.v
// 用途    : 发送引擎吞吐测量
//           单 VL、BAG=1（合成满负载）、tx_ready 常 1，连续发送 200 帧
//           统计总字节数 / 总周期数 -> 等效 Mbps（50 MHz、1 字节/周期总线）
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_perf;

    localparam CLK_NS  = 20;
    localparam N_FRAME = 200;

    reg clk = 0;
    reg reset = 1;
    always #(CLK_NS/2) clk = ~clk;

    reg          cfg_wr = 0, enable = 0;
    reg  [1:0]   cfg_vl = 0;
    reg  [2:0]   cfg_field = 0;
    reg  [207:0] cfg_data = 0;
    reg          tx_ready = 1;

    wire [7:0]  tx_data;
    wire        tx_valid;
    wire        busy, frame_done;
    wire [1:0]  done_vl;
    wire [15:0] frame_len;
    wire [15:0] tx_frames;

    afdx_tx_path #(.N_VL(4), .VW(2), .CW(32), .IFG_CYCLES(4)) dut (
        .clk(clk), .reset(reset),
        .cfg_wr(cfg_wr), .cfg_vl(cfg_vl), .cfg_field(cfg_field), .cfg_data(cfg_data),
        .enable(enable),
        .mac_tx_data(tx_data), .mac_tx_valid(tx_valid), .mac_tx_ready(tx_ready),
        .busy(busy), .frame_done(frame_done), .done_vl(done_vl), .frame_len(frame_len),
        .dbg_ip_ck(), .dbg_udp_ck(), .dbg_fcs(), .tx_frame_cnt(tx_frames)
    );

    task cfg_ident;
        input [1:0] vl;
        begin
            @(negedge clk);
            cfg_vl = vl; cfg_field = 3'd0;
            cfg_data = {48'h030000000000, 48'h020000000101,
                        32'h0A000001, 32'h0A000101, 16'h2001, 16'h1001, 16'h1001};
            cfg_wr = 1'b1; @(negedge clk); cfg_wr = 1'b0;
        end
    endtask

    task cfg_word;
        input [1:0] vl;
        input [2:0] field;
        input [207:0] data;
        begin
            @(negedge clk);
            cfg_vl = vl; cfg_field = field; cfg_data = data;
            cfg_wr = 1'b1; @(negedge clk); cfg_wr = 1'b0;
        end
    endtask

    integer n_bytes, n_cycles;
    real    mbps;

    always @(posedge clk) begin
        if (!reset && enable) n_cycles = n_cycles + 1;
        if (!reset && tx_valid && tx_ready) n_bytes = n_bytes + 1;
    end

    initial begin
        n_bytes = 0; n_cycles = 0;

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        cfg_ident(2'd0);
        cfg_word(2'd0, 3'd1, {176'h0, 32'd1});      // BAG = 1 周期（合成满负载）
        cfg_word(2'd0, 3'd2, {197'h0, 11'd32});     // 功能数据 32 字节
        cfg_word(2'd0, 3'd3, 208'h1);               // 使能

        @(negedge clk);
        n_bytes = 0; n_cycles = 0;
        enable = 1'b1;

        wait (tx_frames >= N_FRAME);
        repeat (5) @(posedge clk);

        mbps = (n_bytes * 8.0) / (n_cycles * CLK_NS * 1.0e-9) / 1.0e6;

        $display("");
        $display("==================== 发送吞吐测量 ====================");
        $display("帧数=%0d  字节数=%0d  周期数=%0d  时钟=%0d ns", tx_frames, n_bytes, n_cycles, CLK_NS);
        $display("平均帧长=%.1f 字节", (n_bytes * 1.0) / (tx_frames * 1.0));
        $display("等效吞吐=%.1f Mbps（总线能力 %0d Mbps）", mbps, (8 * 1000) / CLK_NS);
        if (mbps >= 100.0) $display("RESULT: PASS (>=100 Mbps)");
        else               $display("RESULT: FAIL (<100 Mbps)");
        $display("=====================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("[WARN] 吞吐测试超时");
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
