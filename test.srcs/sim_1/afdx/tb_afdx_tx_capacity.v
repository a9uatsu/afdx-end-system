// =============================================================================
// tb_afdx_tx_capacity.v - S2 32 VL BAG/饿死压测
// 运行: +OUT=<buslog>
// 每条 VL 至少应发送 3 帧；BAG 按索引混合 1/2/4 ms。
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_tx_capacity;
    localparam CLK_NS = 20;
    localparam N_VL   = 32;

    reg clk = 0;
    reg reset = 1;
    always #(CLK_NS/2) clk = ~clk;

    reg          cfg_wr = 0;
    reg  [4:0]   cfg_vl = 0;
    reg  [2:0]   cfg_field = 0;
    reg  [207:0] cfg_data = 0;
    reg          enable = 0;
    reg          tx_ready = 1;

    wire [7:0]  tx_data;
    wire        tx_valid, busy, frame_done;
    wire [4:0]  done_vl;
    wire [15:0] frame_len, tx_frames;

    afdx_tx_path #(.N_VL(N_VL), .VW(5), .SW(3), .CW(32), .IFG_CYCLES(16)) dut (
        .clk(clk), .reset(reset),
        .cfg_wr(cfg_wr), .cfg_vl(cfg_vl), .cfg_field(cfg_field), .cfg_data(cfg_data),
        .enable(enable),
        .mac_tx_data(tx_data), .mac_tx_valid(tx_valid), .mac_tx_ready(tx_ready),
        .busy(busy), .frame_done(frame_done), .done_vl(done_vl), .frame_len(frame_len),
        .dbg_ip_ck(), .dbg_udp_ck(), .dbg_fcs(), .tx_frame_cnt(tx_frames)
    );

    integer fout, i, n_byte;
    integer nframe;
    integer vl_count [0:N_VL-1];
    integer n_under3, min_frames;
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
            if (tx_valid && !prev_valid) nframe = nframe + 1;
            prev_valid <= tx_valid;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < N_VL; i = i + 1) vl_count[i] = 0;
            n_under3 = N_VL;
        end else if (frame_done) begin
            vl_count[done_vl] = vl_count[done_vl] + 1;
            n_under3 = 0;
            for (i = 0; i < N_VL; i = i + 1)
                if (vl_count[i] < 3) n_under3 = n_under3 + 1;
        end
    end

    task cfg_word;
        input [4:0] vl;
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
                0: bag_of = 32'd50000;       // 1 ms
                1: bag_of = 32'd100000;      // 2 ms
                default: bag_of = 32'd200000;// 4 ms
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
        fout = 0; n_byte = 0; nframe = 0; prev_valid = 1'b0;
        if (!$value$plusargs("OUT=%s", out_file)) begin
            $display("[FAIL] missing +OUT"); $finish;
        end

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);
        fout = $fopen(out_file, "w");
        if (fout == 0) begin $display("[FAIL] open OUT"); $finish; end

        for (i = 0; i < N_VL; i = i + 1) begin
            cfg_word(i[4:0], 3'd0,
                {48'h030000000000, 48'h020000000101,
                 32'h0A000000 + i[15:0] + 16'd1,
                 32'h0A000101, 16'h3000 + i[15:0],
                 16'h1001, 16'h3000 + i[15:0]});
            cfg_word(i[4:0], 3'd1, {176'h0, bag_of(i)});
            cfg_word(i[4:0], 3'd2, {197'h0, len_of(i)});
            cfg_word(i[4:0], 3'd3, 208'h1);
        end

        enable = 1'b1;
        wait (n_under3 == 0);
        wait (!tx_valid && !busy);
        repeat (60) @(posedge clk);
        $fclose(fout);
        fout = 0;

        $display("");
        $display("==================== 32 VL 容量压测 ====================");
        min_frames = 1000000;
        for (i = 0; i < N_VL; i = i + 1)
            if (vl_count[i] < min_frames) min_frames = vl_count[i];
        $display("发送帧数=%0d 字节数=%0d 单VL最少帧=%0d",
                 tx_frames, n_byte, min_frames);
        $display("RESULT: TX_CAPACITY_DONE");
        $display("========================================================");
        $finish;
    end

    initial begin
        #15_000_000;
        $display("[WARN] TX capacity timeout frames=%0d", tx_frames);
        $display("RESULT: TIMEOUT");
        $finish;
    end
endmodule
