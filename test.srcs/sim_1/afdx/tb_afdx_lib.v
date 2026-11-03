// =============================================================================
// 文件名  : tb_afdx_lib.v
// 用途    : 底层库单元测试（CRC-32 / 16 位反码校验和），自校验
// 运行    : +VEC=<向量文件路径>
// 向量格式: <tag> <nbytes> <64 个字节值> <exp_crc> <exp_ck> <udp_flag>
//           期望值由 Python 独立计算（scripts/gen_vectors.py），
//           与被测 RTL 无任何共享实现，构成独立比对。
// =============================================================================
`timescale 1ns/1ps
`include "afdx_defs.vh"

module tb_afdx_lib;

    reg clk = 0;
    reg reset = 1;
    always #10 clk = ~clk;

    // ---------------- DUT 1: CRC32 ----------------
    reg         crc_init = 0, crc_en = 0;
    reg  [7:0]  crc_din = 8'h00;
    wire [31:0] crc_val, fcs_val;

    afdx_crc32 u_crc (
        .clk(clk), .reset(reset), .init(crc_init), .en(crc_en),
        .din(crc_din), .crc(crc_val), .fcs(fcs_val)
    );

    // ---------------- DUT 2: 16 位校验和 ----------------
    reg         ck_init = 0, ck_en = 0, ck_fin = 0, ck_udp = 0;
    reg  [7:0]  ck_din = 8'h00;
    wire [15:0] ck_sum;
    wire        ck_valid;

    afdx_checksum16 u_ck (
        .clk(clk), .reset(reset), .init(ck_init), .en(ck_en), .din(ck_din),
        .finalize(ck_fin), .udp_zero_to_ones(ck_udp),
        .checksum(ck_sum), .valid(ck_valid)
    );

    // ---------------- 向量读取与控制 ----------------
    reg [8*256-1:0] vec_file;
    reg [8*64-1:0]  tag;
    integer         fd, rc, i, k;
    integer         n_case, n_pass, n_fail;
    integer         nbytes, v, exp_crc, exp_ck, udp_flag;
    reg [7:0]       bvec [0:63];
    reg [31:0]      got_crc;
    reg [15:0]      got_ck;

    initial begin
        n_case = 0; n_pass = 0; n_fail = 0;

        if (!$value$plusargs("VEC=%s", vec_file)) begin
            $display("[FAIL] 未指定向量文件 +VEC=<path>");
            $finish;
        end
        $display("[INFO] AFDX 底层库自校验开始, 向量文件 = %0s", vec_file);

        repeat (4) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        fd = $fopen(vec_file, "r");
        if (fd == 0) begin
            $display("[FAIL] 无法打开向量文件");
            $finish;
        end

        rc = $fscanf(fd, "%s %d", tag, nbytes);
        while (rc == 2) begin
            for (i = 0; i < 64; i = i + 1) begin
                k = $fscanf(fd, "%d", v);
                if (i < nbytes) bvec[i] = v[7:0];
            end
            k = $fscanf(fd, "%d %d %d", exp_crc, exp_ck, udp_flag);

            // ---- 驱动 CRC 与校验和 ----
            @(negedge clk); crc_init = 1; ck_init = 1; ck_udp = udp_flag[0];
            @(negedge clk); crc_init = 0; ck_init = 0;
            for (i = 0; i < nbytes; i = i + 1) begin
                @(negedge clk); crc_en = 1; ck_en = 1;
                crc_din = bvec[i]; ck_din = bvec[i];
            end
            @(negedge clk); crc_en = 0; ck_en = 0; ck_fin = 1;
            @(negedge clk); ck_fin = 0;
            repeat (2) @(posedge clk);

            got_crc = fcs_val;
            got_ck  = ck_sum;
            n_case  = n_case + 1;

            if (got_crc === exp_crc[31:0] && got_ck === exp_ck[15:0]) begin
                n_pass = n_pass + 1;
                $display("[PASS] %-16s n=%0d crc=0x%08h ck=0x%04h", tag, nbytes, got_crc, got_ck);
            end else begin
                n_fail = n_fail + 1;
                $display("[FAIL] %-16s n=%0d crc got=0x%08h exp=0x%08h | ck got=0x%04h exp=0x%04h",
                         tag, nbytes, got_crc, exp_crc, got_ck, exp_ck);
            end

            rc = $fscanf(fd, "%s %d", tag, nbytes);
        end
        $fclose(fd);

        $display("");
        $display("==================== 底层库测试汇总 ====================");
        $display("用例数=%0d  通过=%0d  失败=%0d", n_case, n_pass, n_fail);
        if (n_fail == 0 && n_case > 0) $display("RESULT: PASS");
        else                            $display("RESULT: FAIL");
        $display("=======================================================");
        $finish;
    end

endmodule
