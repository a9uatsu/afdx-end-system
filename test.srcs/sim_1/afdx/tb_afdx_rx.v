// =============================================================================
// 文件名  : tb_afdx_rx.v
// 用途    : AFDX 接收通路仿真（帧由 Python 生成，含错误注入）
// 运行    : +FRAMES=<帧文件> +OUT=<交付记录文件>
// 说明    : 本测试平台只负责驱动 MAC 接收总线与记录交付结果；
//           期望结果由 scripts/gen_rx_frames.py 生成，
//           由 scripts/check_rx.py 独立比对。
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_rx;

    localparam CLK_NS = 20;

    reg clk = 0;
    reg reset = 1;
    always #(CLK_NS/2) clk = ~clk;

    // ---------------- DUT ----------------
    reg  [7:0]  rx_data = 8'h00;
    reg         rx_valid = 1'b0;
    wire        rx_ready;
    reg         cfg_wr = 1'b0;
    reg  [2:0]  cfg_vl = 3'd0;
    reg  [15:0] cfg_vlid = 16'h0;
    reg         cfg_en = 1'b0;

    wire        dly_valid, dly_start, dly_end;
    wire [7:0]  dly_data;
    wire [15:0] dly_vlid;
    wire [7:0]  dly_sn;
    wire [10:0] dly_plen;

    wire [15:0] rx_frames_cnt, rx_deliv_cnt, rx_err_cnt;
    wire [15:0] rm_accept_cnt, rm_dup_cnt, rm_oos_cnt, rm_unknown_cnt, ic_err_cnt;
    reg  [7:0]  vl_fault_vec;
    wire [3:0]  last_err_code;
    reg  [11:0] vl_status_idx = 12'd0;
    reg         vl_status_req = 1'b0;
    wire [7:0]  vl_status_data;
    wire        vl_status_ready;

    afdx_rx_path #(.N_VL(8), .VW(3), .PAY_BUF(1536)) dut (
        .clk(clk), .reset(reset),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .cfg_wr(cfg_wr), .cfg_vl(cfg_vl), .cfg_vlid(cfg_vlid), .cfg_en(cfg_en),
        .dly_valid(dly_valid), .dly_start(dly_start), .dly_end(dly_end),
        .dly_data(dly_data),
        .dly_vlid(dly_vlid), .dly_sn(dly_sn), .dly_plen(dly_plen),
        .rx_frames_cnt(rx_frames_cnt), .rx_deliv_cnt(rx_deliv_cnt),
        .rx_err_cnt(rx_err_cnt), .rm_accept_cnt(rm_accept_cnt),
        .rm_dup_cnt(rm_dup_cnt), .rm_oos_cnt(rm_oos_cnt),
        .rm_unknown_cnt(rm_unknown_cnt), .ic_err_cnt(ic_err_cnt),
        .vl_status_idx(vl_status_idx), .vl_status_req(vl_status_req),
        .vl_status_data(vl_status_data), .vl_status_ready(vl_status_ready),
        .last_err_code(last_err_code)
    );

    // ---------------- 交付捕获 ----------------
    reg  [7:0]  dbuf [0:2047];
    integer     d_len, n_deliv, j, n_dly_err;
    reg         in_dly;
    reg  [15:0] d_vlid;
    reg  [7:0]  d_sn;
    integer     fd_out;
    time        t_first, lat, max_lat, min_lat;
    reg [8*256-1:0] out_file;

    always @(posedge clk) begin
        if (!reset) begin
            if (dly_valid) begin
                if (dly_start) begin
                    in_dly <= 1'b1;
                    d_vlid <= dly_vlid;
                    d_sn   <= dly_sn;
                    dbuf[0] <= dly_data;
                    d_len   <= 1;
                end else begin
                    dbuf[d_len] <= dly_data;
                    d_len       <= d_len + 1;
                end
            end
            // 交付结束：按锁存的元数据与长度落盘（零长度载荷同样记录）
            if (dly_end) begin
                in_dly <= 1'b0;
                lat = $time - t_first;
                if (lat > max_lat) max_lat = lat;
                if (lat < min_lat) min_lat = lat;
                $fwrite(fd_out, "D %0d %0d %0d", dly_vlid, dly_sn, dly_plen);
                for (j = 0; j < dly_plen; j = j + 1)
                    $fwrite(fd_out, " %02x", dbuf[j]);
                $fwrite(fd_out, "\n");
                n_deliv <= n_deliv + 1;
                if (in_dly && (d_len != dly_plen)) begin
                    $display("[FAIL] 交付字节数 %0d != 元数据长度 %0d", d_len, dly_plen);
                    n_dly_err = n_dly_err + 1;
                end
                d_len <= 0;
            end
        end
    end

    // ---------------- 帧驱动 ----------------
    integer fd_in;
    reg [8*256-1:0] frames_file;
    reg [8*16-1:0]  tag;
    integer         rc, rc2, fi, flen, expect, i, v;
    reg [7:0]       fb [0:2047];
    integer         n_frame, n_accept_exp, n_reject_exp, n_dup_exp;

    task send_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_valid = 1'b1;
            rx_data  = b;
            while (!rx_ready) @(negedge clk);
        end
    endtask

    task read_fault_status;
        input  [11:0] idx;
        output        fault_bit;
        begin
            @(negedge clk);
            vl_status_idx = idx;
            vl_status_req = 1'b1;
            while (!vl_status_ready) @(negedge clk);
            fault_bit = vl_status_data[0];
            @(negedge clk);
            vl_status_req = 1'b0;
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        in_dly = 1'b0; d_len = 0; n_deliv = 0; n_frame = 0;
        max_lat = 0; min_lat = 64'd1000000000;
        n_dly_err = 0;
        n_accept_exp = 0; n_reject_exp = 0; n_dup_exp = 0;
        fd_out = 0;

        if (!$value$plusargs("FRAMES=%s", frames_file)) begin
            $display("[FAIL] 未指定 +FRAMES=<帧文件>"); $finish;
        end
        if (!$value$plusargs("OUT=%s", out_file)) begin
            $display("[FAIL] 未指定 +OUT=<交付记录文件>"); $finish;
        end

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        fd_out = $fopen(out_file, "w");
        if (fd_out == 0) begin $display("[FAIL] 无法打开交付记录文件"); $finish; end

        // ---- 配置接收 VL：0 -> 0x2001, 1 -> 0x2002 ----
        @(negedge clk); cfg_wr = 1'b1; cfg_vl = 3'd0; cfg_vlid = 16'h2001; cfg_en = 1'b1;
        @(negedge clk); cfg_vl = 3'd1; cfg_vlid = 16'h2002; cfg_en = 1'b1;
        @(negedge clk); cfg_wr = 1'b0;
        repeat (2) @(posedge clk);

        $display("[INFO] 接收通路测试开始，帧文件=%0s", frames_file);

        // ---- 逐帧发送 ----
        fd_in = $fopen(frames_file, "r");
        if (fd_in == 0) begin $display("[FAIL] 无法打开帧文件"); $finish; end

        rc = $fscanf(fd_in, "%s %d %d %d", tag, fi, flen, expect);
        while (rc == 4) begin
            for (i = 0; i < flen; i = i + 1) begin
                rc2 = $fscanf(fd_in, "%d", v);
                fb[i] = v[7:0];
            end
            n_frame = n_frame + 1;
            if (expect == 0 || expect == 3) n_accept_exp = n_accept_exp + 1;
            else if (expect == 2)           n_dup_exp    = n_dup_exp + 1;
            else                            n_reject_exp = n_reject_exp + 1;

            t_first = $time;
            for (i = 0; i < flen; i = i + 1)
                send_byte(fb[i]);
            // 帧间空闲（帧边界）
            @(negedge clk); rx_valid = 1'b0;
            repeat (6) @(negedge clk);

            rc = $fscanf(fd_in, "%s %d %d %d", tag, fi, flen, expect);
        end
        $fclose(fd_in);

        // 等待最后一帧处理完成
        wait (rx_ready);
        repeat (40) @(posedge clk);
        vl_fault_vec = 8'd0;
        for (i = 0; i < 2; i = i + 1)
            read_fault_status(i[11:0], vl_fault_vec[i]);
        // 把 RTL 计数器写入记录文件，供 check_rx.py 自动比对
        $fwrite(fd_out, "COUNTS accept=%0d dup=%0d oos=%0d unknown=%0d err=%0d ic=%0d fault=%0d\n",
                rm_accept_cnt, rm_dup_cnt, rm_oos_cnt, rm_unknown_cnt,
                rx_err_cnt, ic_err_cnt, vl_fault_vec);
        $fclose(fd_out);
        fd_out = 0;

        $display("");
        $display("==================== 接收通路测试汇总 ====================");
        $display("发送帧数        = %0d  (期望接受 %0d / 重复 %0d / 拒绝 %0d)",
                 n_frame, n_accept_exp, n_dup_exp, n_reject_exp);
        $display("解析帧计数      = %0d", rx_frames_cnt);
        $display("交付帧数        = %0d (RTL计数 %0d, 期望 %0d)",
                 n_deliv, rx_deliv_cnt, n_accept_exp);
        $display("交付字节数异常  = %0d", n_dly_err);
        $display("冗余管理: 接受=%0d 重复=%0d 失序=%0d 未知VL=%0d",
                 rm_accept_cnt, rm_dup_cnt, rm_oos_cnt, rm_unknown_cnt);
        $display("完整性检查错误数= %0d   VL故障向量= %b (二进制)", ic_err_cnt, vl_fault_vec);
        $display("校验错误帧数    = %0d   最后错误码= %0d", rx_err_cnt, last_err_code);
        $display("交付记录文件    = %0s", out_file);
        $display("端到端时延      = min %0d ns / max %0d ns", min_lat, max_lat);
        $display("RESULT: RXLOG_DONE");
        $display("=========================================================");
        $finish;
    end

    // ---------------- 超时保护 ----------------
    // ---------------- 可选：解析器跟踪（+TRACE） ----------------
    always @(posedge clk) begin
        if ($test$plusargs("RMTRACE") && dut.u_rm.meta_valid)
            $display("t=%0t META vlid=0x%04x sn=%0d idx=%0d found=%b accept=%b dup=%b oos=%b last=%0d",
                     $time, dut.u_rm.meta_vlid, dut.u_rm.meta_sn, dut.u_rm.m_idx,
                     dut.u_rm.m_found, dut.u_rm.accept_w, dut.u_rm.is_dup_w,
                     dut.u_rm.oos_w, dut.u_rm.last_sn_w);
    end

    always @(posedge clk) begin
        if ($test$plusargs("DLYTRACE") && (dly_valid || dly_end))
            $display("t=%0t dly_valid=%b start=%b end=%b data=%02x d_len=%0d plen=%0d vlid=0x%04x sn=%0d",
                     $time, dly_valid, dly_start, dly_end, dly_data, d_len, dly_plen,
                     dly_vlid, dly_sn);
    end

    always @(posedge clk) begin
        if ($test$plusargs("TRACE") && (dut.u_parser.state == 4'd1))
            $display("t=%0t PRE f_len=%0d udp_len=%0d ip_tot=%0d lensum=%b",
                     $time, dut.u_parser.f_len, dut.u_parser.udp_len_w, dut.u_parser.ip_tot_w,
                     dut.u_parser.len_sum_bad);
    end

    initial begin
        #20_000_000;
        $display("[WARN] 接收通路仿真超时");
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
