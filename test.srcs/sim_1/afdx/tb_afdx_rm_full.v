// =============================================================================
// tb_afdx_rm_full.v - S5 4096 VLID 二分查找/状态 RAM 压测
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_rm_full;
    localparam N_VL = 4096;
    localparam VW   = 12;

    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg cfg_wr = 0;
    reg [VW-1:0] cfg_vl = 0;
    reg [15:0] cfg_vlid = 0;
    reg cfg_en = 0;
    reg meta_valid = 0;
    reg [15:0] meta_vlid = 0;
    reg [7:0] meta_sn = 0;
    wire accept, rm_ready;
    wire [15:0] cnt_accept, cnt_dup, cnt_oos, cnt_unknown, cnt_ic_err;
    reg  [11:0] status_idx = 12'd0;
    reg         status_req = 1'b0;
    wire [7:0]  status_data;
    wire        status_ready;
    wire [15:0] rm_vlid_dbg;
    wire [VW-1:0] rm_idx_dbg;

    afdx_rm_rx #(
        .N_VL(N_VL), .VW(VW), .SEARCH_W(13),
        .IC_WINDOW(16), .IC_THRESH(3)
    ) dut (
        .clk(clk), .reset(reset),
        .cfg_wr(cfg_wr), .cfg_vl(cfg_vl), .cfg_vlid(cfg_vlid), .cfg_en(cfg_en),
        .meta_valid(meta_valid), .meta_vlid(meta_vlid), .meta_sn(meta_sn),
        .accept(accept), .rm_ready(rm_ready),
        .status_req(status_req), .status_idx(status_idx[VW-1:0]),
        .status_data(status_data), .status_ready(status_ready),
        .cnt_accept(cnt_accept), .cnt_dup(cnt_dup), .cnt_oos(cnt_oos),
        .cnt_unknown(cnt_unknown), .cnt_ic_err(cnt_ic_err),
        .rm_vlid_dbg(rm_vlid_dbg), .rm_idx_dbg(rm_idx_dbg)
    );

    integer i, n_err;
    reg [7:0] status_byte;

    task cfg_one;
        input integer idx;
        begin
            @(negedge clk);
            cfg_wr = 1'b1;
            cfg_vl = idx[VW-1:0];
            cfg_vlid = 16'h4000 + idx * 4;
            cfg_en = 1'b1;
        end
    endtask

    task send_frame;
        input [15:0] vlid;
        input [7:0] sn;
        input exp_accept;
        begin
            @(negedge clk);
            meta_valid = 1'b1;
            meta_vlid = vlid;
            meta_sn = sn;
            @(negedge clk);
            meta_valid = 1'b0;
            while (!rm_ready) @(negedge clk);
            if (accept !== exp_accept) begin
                $display("[FAIL] vlid=%04x sn=%0d accept=%b exp=%b",
                         vlid, sn, accept, exp_accept);
                n_err = n_err + 1;
            end
        end
    endtask

    task read_status;
        input [11:0] idx;
        output [7:0] data;
        begin
            @(negedge clk);
            status_idx = idx;
            status_req = 1'b1;
            while (!status_ready) @(negedge clk);
            data = status_data;
            @(negedge clk);
            status_req = 1'b0;
        end
    endtask

    initial begin
        n_err = 0;
        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        // 配置表必须按索引升序写 VLID。
        for (i = 0; i < N_VL; i = i + 1)
            cfg_one(i);
        @(negedge clk);
        cfg_wr = 1'b0;

        for (i = 0; i < N_VL; i = i + 1) begin
            send_frame(16'h4000 + i * 4, 8'd10, 1'b1); // 首帧
            send_frame(16'h4000 + i * 4, 8'd10, 1'b0); // 重复
        end

        // 第一条 VL 注入 3 次前向失序，触发完整性故障。
        send_frame(16'h4000, 8'd12, 1'b1);
        send_frame(16'h4000, 8'd14, 1'b1);
        send_frame(16'h4000, 8'd16, 1'b1);

        if (cnt_accept != 16'd4099) begin
            $display("[FAIL] accept=%0d exp=4099", cnt_accept); n_err = n_err + 1;
        end
        if (cnt_dup != 16'd4096) begin
            $display("[FAIL] dup=%0d exp=4096", cnt_dup); n_err = n_err + 1;
        end
        if (cnt_oos != 16'd3) begin
            $display("[FAIL] oos=%0d exp=3", cnt_oos); n_err = n_err + 1;
        end
        if (cnt_ic_err != 16'd3) begin
            $display("[FAIL] ic=%0d exp=3", cnt_ic_err); n_err = n_err + 1;
        end
        if (cnt_unknown != 16'd0) begin
            $display("[FAIL] unknown=%0d", cnt_unknown); n_err = n_err + 1;
        end
        read_status(12'd0, status_byte);
        if (status_byte[0] !== 1'b1) begin
            $display("[FAIL] VL0 fault status=%h", status_byte); n_err = n_err + 1;
        end
        read_status(12'd1, status_byte);
        if (status_byte[0] !== 1'b0) begin
            $display("[FAIL] VL1 unexpected fault=%h", status_byte); n_err = n_err + 1;
        end
        read_status(12'd64, status_byte);
        if (status_byte[0] !== 1'b0) begin
            $display("[FAIL] VL64 unexpected fault=%h", status_byte); n_err = n_err + 1;
        end
        read_status(12'd4095, status_byte);
        if (status_byte[0] !== 1'b0) begin
            $display("[FAIL] VL4095 unexpected fault=%h", status_byte); n_err = n_err + 1;
        end

        $display("");
        $display("==================== 4096 VLID RM 压测 ====================");
        $display("accept=%0d dup=%0d oos=%0d ic=%0d unknown=%0d",
                 cnt_accept, cnt_dup, cnt_oos, cnt_ic_err, cnt_unknown);
        $display("RESULT: %s", n_err == 0 ? "PASS" : "FAIL");
        $display("=======================================================");
        $finish;
    end

    initial begin
        #30_000_000;
        $display("RESULT: TIMEOUT");
        $finish;
    end
endmodule
