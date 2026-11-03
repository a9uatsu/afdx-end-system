// =============================================================================
// tb_afdx_soak.v - 128 VL 长时容量与 BAG 压测
// 运行: +OUT=<buslog> [+NFRAME=12000] [+MINVL=20]
// 配置: BAG 按索引混合 1/2/4 ms；功能数据长度混合 0/16/32/64 字节。
// 判定: Python 独立检查字段、校验和、FCS、SN、BAG、抖动与饿死。
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_soak;
    localparam CLK_NS = 20;
    localparam N_VL   = 128;

    reg clk = 0;
    reg reset = 1;
    always #(CLK_NS/2) clk = ~clk;

    reg          cfg_wr = 0;
    reg  [6:0]   cfg_vl = 0;
    reg  [2:0]   cfg_field = 0;
    reg  [207:0] cfg_data = 0;
    reg          enable = 0;
    reg          tx_ready = 1;

    wire [7:0]  tx_data;
    wire        tx_valid, busy, frame_done;
    wire [6:0]  done_vl;
    wire [15:0] frame_len, tx_frames;

    afdx_tx_path #(.N_VL(N_VL), .VW(7), .SW(5), .CW(32), .IFG_CYCLES(16)) dut (
        .clk(clk), .reset(reset),
        .cfg_wr(cfg_wr), .cfg_vl(cfg_vl), .cfg_field(cfg_field), .cfg_data(cfg_data),
        .enable(enable),
        .mac_tx_data(tx_data), .mac_tx_valid(tx_valid), .mac_tx_ready(tx_ready),
        .busy(busy), .frame_done(frame_done), .done_vl(done_vl), .frame_len(frame_len),
        .dbg_ip_ck(), .dbg_udp_ck(), .dbg_fcs(), .tx_frame_cnt(tx_frames)
    );

    integer fout, i, n_byte, target_frames, min_required;
    integer vl_count [0:N_VL-1];
    integer n_under, min_frames;
    reg [8*256-1:0] out_file;
    reg prev_valid;

    always @(posedge clk) begin
        if (!reset && fout != 0) begin
            if (tx_valid && tx_ready) begin
                $fwrite(fout, "B %0t %02x\n", $time, tx_data);
                n_byte = n_byte + 1;
            end else if (!tx_valid) begin
                if (prev_valid) $fwrite(fout, "I %0t\n", $time);
            end
            prev_valid <= tx_valid;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < N_VL; i = i + 1)
                vl_count[i] = 0;
            n_under = N_VL;
        end else if (frame_done) begin
            vl_count[done_vl] = vl_count[done_vl] + 1;
            n_under = 0;
            for (i = 0; i < N_VL; i = i + 1)
                if (vl_count[i] < min_required)
                    n_under = n_under + 1;
        end
    end

    task cfg_word;
        input [6:0] vl;
        input [2:0] field;
        input [207:0] data;
        begin
            @(negedge clk);
            cfg_vl = vl; cfg_field = field; cfg_data = data;
            cfg_wr = 1'b1;
            @(negedge clk);
            cfg_wr = 1'b0;
        end
    endtask

    function [31:0] bag_of;
        input integer k;
        begin
            case (k % 3)
                0: bag_of = 32'd50000;        // 1 ms
                1: bag_of = 32'd100000;       // 2 ms
                default: bag_of = 32'd200000; // 4 ms
            endcase
        end
    endfunction

    function [10:0] len_of;
        input integer k;
        begin
            case (k % 4)
                0: len_of = 11'd0;
                1: len_of = 11'd16;
                2: len_of = 11'd32;
                default: len_of = 11'd64;
            endcase
        end
    endfunction

    initial begin
        fout = 0; n_byte = 0; prev_valid = 1'b0;
        target_frames = 12000;
        min_required = 20;
        if (!$value$plusargs("OUT=%s", out_file)) begin
            $display("[FAIL] missing +OUT");
            $finish;
        end
        if (!$value$plusargs("NFRAME=%d", target_frames))
            target_frames = 12000;
        if (!$value$plusargs("MINVL=%d", min_required))
            min_required = 20;

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);
        fout = $fopen(out_file, "w");
        if (fout == 0) begin
            $display("[FAIL] open OUT");
            $finish;
        end

        // 配置 128 条发送 VL，低两位交错写入 VL 表 bank。
        for (i = 0; i < N_VL; i = i + 1) begin
            cfg_word(i[6:0], 3'd0,
                {48'h030000000000, 48'h020000000101,
                 16'h0A00, 16'h0000 + i[15:0] + 16'd1,
                 32'h0A000101, 16'h3000 + i[15:0],
                 16'h1001, 16'h3000 + i[15:0]});
            cfg_word(i[6:0], 3'd1, {176'h0, bag_of(i)});
            cfg_word(i[6:0], 3'd2, {197'h0, len_of(i)});
            cfg_word(i[6:0], 3'd3, 208'h1);
        end

        enable = 1'b1;
        wait (tx_frames >= target_frames);
        wait (!tx_valid && !busy);
        repeat (60) @(posedge clk);
        $fclose(fout);
        fout = 0;

        min_frames = 1000000;
        for (i = 0; i < N_VL; i = i + 1)
            if (vl_count[i] < min_frames)
                min_frames = vl_count[i];

        $display("");
        $display("==================== AFDX long soak ====================");
        $display("target_frames=%0d frames=%0d bytes=%0d min_vl_frames=%0d min_required=%0d",
                 target_frames, tx_frames, n_byte, min_frames, min_required);
        $display("RESULT: SOAK_LOG_DONE");
        $display("=======================================================");
        $finish;
    end

    initial begin
        #1_000_000_000;
        $display("[FAIL] soak timeout frames=%0d", tx_frames);
        $display("RESULT: TIMEOUT");
        $finish;
    end
endmodule
