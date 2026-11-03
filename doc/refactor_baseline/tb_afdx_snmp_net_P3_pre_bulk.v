// =============================================================================
// 文件名  : tb_afdx_snmp_net.v
// 用途    : SNMP 管理通道端到端测试
//           RX 注入 以太网/IP/UDP/SNMP GetRequest 帧 -> ES 核心 -> TX 抓响应帧
//           提取响应 UDP 载荷，由 check_snmp.py 与 Python 期望逐字节比对
// 运行    : +FRAMES=<snmp_frames.txt> +OUT=<resp_dump.txt>
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_snmp_net;

    localparam CLK_NS = 20;

    reg clk = 0;
    reg reset = 1;
    always #(CLK_NS/2) clk = ~clk;

    // ---------------- DUT: ES 核心（不使能 AFDX 发送，专测管理通道） ----------------
    reg  [7:0] rx_data = 8'h00;
    reg        rx_valid = 1'b0;
    reg        tx_ready = 1'b1;
    wire [7:0] tx_data;
    wire       tx_valid;

    reg         tx_cfg_wr = 0, tx_enable = 0;
    reg  [1:0]  tx_cfg_vl = 0;
    reg  [2:0]  tx_cfg_field = 0;
    reg  [207:0] tx_cfg_data = 0;
    reg         rx_cfg_wr = 0, rx_cfg_en = 0;
    reg  [2:0]  rx_cfg_vl = 0;
    reg  [15:0] rx_cfg_vlid = 0;

    wire [15:0] snmp_req, snmp_resp, snmp_drop, snmp_nosuch;
    wire [15:0] dummy16;
    wire [7:0]  dummy_fault;
    wire [3:0]  dummy_code;
    wire        dly_valid, dly_start, dly_end;
    wire [7:0]  dly_data;
    wire [15:0] dly_vlid;
    wire [7:0]  dly_sn;
    wire [10:0] dly_plen;

    afdx_es_core #(.N_TX_VL(4), .TVW(2), .N_RX_VL(8), .RVW(3), .DUAL(0)) dut (
        .clk(clk), .reset(reset),
        .tx_a_data(tx_data), .tx_a_valid(tx_valid), .tx_a_ready(tx_ready),
        .rx_a_data(rx_data), .rx_a_valid(rx_valid), .rx_a_accept(),
        .tx_b_data(), .tx_b_valid(), .tx_b_ready(1'b1),
        .rx_b_data(8'h00), .rx_b_valid(1'b0), .rx_b_accept(),
        .tx_cfg_wr(tx_cfg_wr), .tx_cfg_vl(tx_cfg_vl),
        .tx_cfg_field(tx_cfg_field), .tx_cfg_data(tx_cfg_data),
        .tx_enable(tx_enable),
        .rx_cfg_wr(rx_cfg_wr), .rx_cfg_vl(rx_cfg_vl),
        .rx_cfg_vlid(rx_cfg_vlid), .rx_cfg_en(rx_cfg_en),
        .tx_busy(), .tx_frames(), .tx_frame_len(),
        .dly_valid(dly_valid), .dly_start(dly_start), .dly_end(dly_end),
        .dly_data(dly_data), .dly_vlid(dly_vlid), .dly_sn(dly_sn), .dly_plen(dly_plen),
        .rx_frames(), .rx_deliv(), .rx_err(),
        .rm_accept(), .rm_dup(), .rm_oos(), .rm_unknown(), .ic_err(),
        .vl_fault(dummy_fault), .dbg_err_code(dummy_code), .rx_drop(dummy16),
        .snmp_req(snmp_req), .snmp_resp(snmp_resp),
        .snmp_drop(snmp_drop), .snmp_nosuch(snmp_nosuch)
    );

    // ---------------- TX 帧捕获 ----------------
    reg [7:0]  fbuf [0:2047];
    integer    flen, fidx, j, fd_out, n_frames;
    reg        in_frame, prev_valid;
    reg [8*256-1:0] out_file, frames_file;

    always @(posedge clk) begin
        if (!reset) begin
            if (tx_valid && tx_ready) begin
                if (!in_frame) begin
                    in_frame <= 1'b1;
                    fbuf[0]  <= tx_data;
                    flen     <= 1;
                end else begin
                    fbuf[flen] <= tx_data;
                    flen       <= flen + 1;
                end
            end else if (!tx_valid && in_frame) begin
                in_frame <= 1'b0;
                // 提取 UDP 载荷：42 起始，长度 = UDP 长度 - 8
                if (flen >= 42) begin
                    $fwrite(fd_out, "R %0d %0d", fidx,
                            ({fbuf[38], fbuf[39]} - 8));
                    for (j = 0; j < ({fbuf[38], fbuf[39]} - 8); j = j + 1)
                        $fwrite(fd_out, " %0d", fbuf[42 + j]);
                    $fwrite(fd_out, "\n");
                    n_frames <= n_frames + 1;
                end
                fidx <= fidx + 1;
            end
        end
    end

    // ---------------- 帧驱动 ----------------
    always @(posedge clk) begin
        if ($test$plusargs("TRACE") && (dut.g_mgmt.u_mgmt.rst != 3'd0 || dut.g_mgmt.u_mgmt.tst != 5'd0))
            $display("t=%0t rst=%0d tst=%0d plen=%0d pw=%0d feed_i=%0d paylen=%0d respv=%b txv=%b txfree=%b k=%0d",
                     $time, dut.g_mgmt.u_mgmt.rst, dut.g_mgmt.u_mgmt.tst, dut.g_mgmt.u_mgmt.plen,
                     dut.g_mgmt.u_mgmt.pwptr, dut.g_mgmt.u_mgmt.feed_i, dut.g_mgmt.u_mgmt.payload_len,
                     dut.g_mgmt.u_mgmt.resp_valid,
                     tx_valid, dut.g_mgmt.u_mgmt.tx_free, dut.g_mgmt.u_mgmt.k);
    end

    integer fd_in, rc, rc2, fid, len, i, v;
    reg [7:0]  fb [0:2047];
    reg [8*16-1:0] tag;

    task send_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_valid = 1'b1;
            rx_data  = b;
        end
    endtask

    initial begin
        in_frame = 0; flen = 0; fidx = 0; n_frames = 0; fd_out = 0;

        if (!$value$plusargs("FRAMES=%s", frames_file)) begin
            $display("[FAIL] 未指定 +FRAMES"); $finish;
        end
        if (!$value$plusargs("OUT=%s", out_file)) begin
            $display("[FAIL] 未指定 +OUT"); $finish;
        end

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (3) @(posedge clk);

        fd_out = $fopen(out_file, "w");
        fd_in  = $fopen(frames_file, "r");
        if (fd_out == 0 || fd_in == 0) begin
            $display("[FAIL] 文件打开失败"); $finish;
        end
        $display("[INFO] SNMP 网络端到端测试开始");

        rc = $fscanf(fd_in, "%s %d %d", tag, fid, len);
        while (rc == 3) begin
            for (i = 0; i < len; i = i + 1) begin
                rc2 = $fscanf(fd_in, "%d", v);
                fb[i] = v[7:0];
            end
            for (i = 0; i < len; i = i + 1)
                send_byte(fb[i]);
            @(negedge clk); rx_valid = 1'b0;
            repeat (2000) @(negedge clk);      // 帧间间隔 + 留出处理/响应时间
            rc = $fscanf(fd_in, "%s %d %d", tag, fid, len);
        end
        $fclose(fd_in);

        repeat (500) @(posedge clk);
        $fwrite(fd_out, "COUNTS req=%0d resp=%0d drop=%0d nosuch=%0d\n",
                snmp_req, snmp_resp, snmp_drop, snmp_nosuch);
        $fclose(fd_out);
        fd_out = 0;

        $display("");
        $display("==================== SNMP 网络测试汇总 ====================");
        $display("请求=%0d 响应=%0d 丢弃=%0d 未知OID=%0d  抓帧=%0d",
                 snmp_req, snmp_resp, snmp_drop, snmp_nosuch, n_frames);
        $display("RESULT: SNMP_NET_LOG_DONE");
        $display("===========================================================");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("[WARN] SNMP 网络测试超时");
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
