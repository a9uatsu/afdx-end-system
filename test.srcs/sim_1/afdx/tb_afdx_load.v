// =============================================================================
// 文件名  : tb_afdx_load.v
// 用途    : ARINC 615A 风格加载器单元测试
// 运行    : +VEC=<load_vectors.txt> +OUT=<resp_dump.txt>
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_load;

    reg clk = 0;
    reg reset = 1;
    always #10 clk = ~clk;

    reg        msg_wr = 0, msg_last = 0, msg_start = 0;
    reg [7:0]  msg_data = 8'h00;
    wire       resp_valid, resp_last, resp_begin;
    wire [7:0] resp_data;
    wire [15:0] img_len, req_cnt, err_cnt;
    wire [31:0] img_crc;
    wire        loaded;

    afdx_load_615a dut (
        .clk(clk), .reset(reset),
        .msg_wr(msg_wr), .msg_data(msg_data), .msg_last(msg_last), .msg_start(msg_start),
        .img_len(img_len), .img_crc(img_crc), .loaded(loaded),
        .req_cnt(req_cnt), .err_cnt(err_cnt),
        .resp_valid(resp_valid), .resp_data(resp_data), .resp_last(resp_last),
        .resp_begin(resp_begin)
    );

    integer fd_out, fd_in, rc, rc2, fid, len, i, v, n_resp, j;
    reg [8*256-1:0] out_file, vec_file;
    reg [8*16-1:0]  tag;
    reg [7:0] fb [0:1023];
    reg [7:0] rb [0:15];
    integer rlen, cur_id;

    always @(posedge clk) begin
        if (!reset && resp_valid) begin
            rb[rlen] <= resp_data;
            if (resp_last) begin
                $fwrite(fd_out, "R %0d %0d", cur_id, rlen + 1);
                for (j = 0; j < rlen; j = j + 1)
                    $fwrite(fd_out, " %0d", rb[j]);
                $fwrite(fd_out, " %0d\n", resp_data);
                rlen   <= 0;
                n_resp <= n_resp + 1;
            end else begin
                rlen <= rlen + 1;
            end
        end
    end

    initial begin
        rlen = 0; n_resp = 0; cur_id = 0; fd_out = 0;

        if (!$value$plusargs("VEC=%s", vec_file)) begin $display("[FAIL] no VEC"); $finish; end
        if (!$value$plusargs("OUT=%s", out_file)) begin $display("[FAIL] no OUT"); $finish; end

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        fd_out = $fopen(out_file, "w");
        fd_in  = $fopen(vec_file, "r");
        if (fd_out == 0 || fd_in == 0) begin $display("[FAIL] file open"); $finish; end

        rc = $fscanf(fd_in, "%s %d %d", tag, fid, len);
        while (rc == 3) begin
            for (i = 0; i < len; i = i + 1) begin
                rc2 = $fscanf(fd_in, "%d", v);
                fb[i] = v[7:0];
            end
            cur_id = fid;

            @(negedge clk); msg_start = 1'b1;
            @(negedge clk); msg_start = 1'b0;
            for (i = 0; i < len; i = i + 1) begin
                @(negedge clk);
                msg_wr   = 1'b1;
                msg_data = fb[i];
                msg_last = (i == len - 1);
            end
            @(negedge clk); msg_wr = 1'b0; msg_last = 1'b0;

            repeat (1200) @(posedge clk);   // 足够写完 512 字节块并响应
            rc = $fscanf(fd_in, "%s %d %d", tag, fid, len);
        end
        $fclose(fd_in);

        repeat (50) @(posedge clk);
        $fclose(fd_out);
        fd_out = 0;

        $display("");
        $display("==================== 615A 加载器测试汇总 ====================");
        $display("请求=%0d 响应=%0d 镜像长度=%0d CRC=0x%08h loaded=%b 错误=%0d",
                 req_cnt, n_resp, img_len, img_crc, loaded, err_cnt);
        $display("RESULT: LOAD_LOG_DONE");
        $display("===========================================================");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("[WARN] 615A 测试超时"); $display("RESULT: TIMEOUT"); $finish;
    end

endmodule
