// =============================================================================
// 文件名  : tb_afdx_snmp.v
// 用途    : SNMP v2c Agent 单元测试（请求由 Python 生成，响应逐字节比对）
// 运行    : +VEC=<snmp_vectors.txt> +OUT=<response_dump.txt>
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_snmp;

    localparam CLK_NS = 20;

    reg clk = 0;
    reg reset = 1;
    always #(CLK_NS/2) clk = ~clk;

    // ---------------- 固定 MIB 值（与 gen_snmp_vectors.py 一致） ----------------
    localparam [31:0] V_UPTIME = 32'h00001234;
    localparam [31:0] V_TX     = 32'd42;
    localparam [31:0] V_RX     = 32'd256;
    localparam [31:0] V_RXERR  = 32'd3;
    localparam [31:0] V_DUP    = 32'd5;
    localparam [31:0] V_ICERR  = 32'd7;
    reg       [7:0]  vl_fault_reg = 8'h05;
    localparam [15:0] V_CAP    = 16'd4096;

    reg         req_wr = 0, req_last = 0, req_start = 0;
    reg  [7:0]  req_data = 8'h00;
    wire        resp_valid, resp_last, resp_begin;
    wire [7:0]  resp_data;
    wire [15:0] req_cnt, resp_cnt, drop_cnt, no_such_cnt;
    wire        trap_valid, trap_last, trap_begin;
    wire [7:0]  trap_data;
    wire [15:0] trap_cnt;

    afdx_snmp_agent dut (
        .clk(clk), .reset(reset),
        .sys_uptime(V_UPTIME), .cnt_tx_frames(V_TX), .cnt_rx_frames(V_RX),
        .cnt_rx_errors(V_RXERR), .cnt_dup(V_DUP), .cnt_ic_err(V_ICERR),
        .vl_fault(vl_fault_reg), .vl_capacity(V_CAP),
        .req_wr(req_wr), .req_data(req_data), .req_last(req_last), .req_start(req_start),
        .resp_valid(resp_valid), .resp_data(resp_data), .resp_last(resp_last),
        .resp_begin(resp_begin),
        .req_cnt(req_cnt), .resp_cnt(resp_cnt), .drop_cnt(drop_cnt),
        .no_such_cnt(no_such_cnt),
        .trap_valid(trap_valid), .trap_data(trap_data), .trap_last(trap_last),
        .trap_begin(trap_begin), .trap_cnt(trap_cnt)
    );

    // ---------------- 响应捕获 ----------------
    integer fd_out;
    reg [8*256-1:0] out_file, vec_file;
    reg [7:0]  rbuf [0:255];
    integer    rlen, cur_id, n_resp, j;
    reg        in_resp;
    reg [7:0]  tbuf [0:255];
    integer    tlen;

    always @(posedge clk) begin
        if (!reset) begin
            // Trap 捕获
            if (trap_valid) begin
                tbuf[tlen] <= trap_data;
                if (trap_last) begin
                    $fwrite(fd_out, "T 0 %0d", tlen + 1);
                    for (j = 0; j < tlen; j = j + 1)
                        $fwrite(fd_out, " %0d", tbuf[j]);
                    $fwrite(fd_out, " %0d\n", trap_data);
                    tlen <= 0;
                end else begin
                    tlen <= tlen + 1;
                end
            end
            if (resp_valid) begin
                rbuf[rlen] <= resp_data;
                if (resp_last) begin
                    $fwrite(fd_out, "R %0d %0d", cur_id, rlen + 1);
                    for (j = 0; j < rlen; j = j + 1)
                        $fwrite(fd_out, " %0d", rbuf[j]);
                    $fwrite(fd_out, " %0d\n", resp_data);
                    rlen   <= 0;
                    n_resp <= n_resp + 1;
                end else begin
                    rlen <= rlen + 1;
                end
            end
        end
    end

    // ---------------- 主流程 ----------------
    integer fd_in, rc, rc2, fid, flen, expect, i, v, n_msg;
    reg [7:0] fb [0:255];
    reg [8*16-1:0] tag;

    initial begin
        rlen = 0; tlen = 0; in_resp = 0; n_resp = 0; n_msg = 0; cur_id = 0; fd_out = 0;

        if (!$value$plusargs("VEC=%s", vec_file)) begin
            $display("[FAIL] 未指定 +VEC"); $finish;
        end
        if (!$value$plusargs("OUT=%s", out_file)) begin
            $display("[FAIL] 未指定 +OUT"); $finish;
        end

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        fd_out = $fopen(out_file, "w");
        fd_in  = $fopen(vec_file, "r");
        if (fd_out == 0 || fd_in == 0) begin
            $display("[FAIL] 文件打开失败"); $finish;
        end
        $display("[INFO] SNMP Agent 测试开始");

        rc = $fscanf(fd_in, "%s %d %d %d", tag, fid, flen, expect);
        while (rc == 4) begin
            for (i = 0; i < flen; i = i + 1) begin
                rc2 = $fscanf(fd_in, "%d", v);
                fb[i] = v[7:0];
            end
            cur_id = fid;
            n_msg  = n_msg + 1;

            // 清指针并写入报文
            @(negedge clk); req_start = 1'b1;
            @(negedge clk); req_start = 1'b0;
            for (i = 0; i < flen; i = i + 1) begin
                @(negedge clk);
                req_wr   = 1'b1;
                req_data = fb[i];
                req_last = (i == flen - 1);
            end
            @(negedge clk); req_wr = 1'b0; req_last = 1'b0;

            // 等待处理与响应流出
            repeat (500) @(posedge clk);

            rc = $fscanf(fd_in, "%s %d %d %d", tag, fid, flen, expect);
        end
        $fclose(fd_in);

        // 触发 Trap：故障位图 0x05 -> 0x07
        @(negedge clk); vl_fault_reg = 8'h07;
        repeat (400) @(posedge clk);

        repeat (50) @(posedge clk);
        $fwrite(fd_out, "COUNTS req=%0d resp=%0d drop=%0d nosuch=%0d\n",
                req_cnt, resp_cnt, drop_cnt, no_such_cnt);
        $fclose(fd_out);
        fd_out = 0;

        $display("");
        $display("==================== SNMP Agent 测试汇总 ====================");
        $display("请求数=%0d  响应数=%0d  丢弃=%0d  未知OID=%0d",
                 req_cnt, resp_cnt, drop_cnt, no_such_cnt);
        $display("Trap 数=%0d", trap_cnt);
        $display("RESULT: SNMP_LOG_DONE");
        $display("=============================================================");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("[WARN] SNMP 仿真超时");
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
