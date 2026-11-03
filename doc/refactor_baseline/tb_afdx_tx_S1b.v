// =============================================================================
// 文件名  : tb_afdx_tx.v
// 用途    : AFDX 发送通路仿真（激励 + MAC 总线逐周期记录）
// 运行    : +OUT=<总线记录文件> [+NFRAME=<帧数, 默认 12>] [+TRACE]
// 记录格式: 每个"状态变化"周期写一行
//             B <t_ns> <byte>   该周期完成一个字节传输（valid&ready）
//             S <t_ns>          该周期为背压停顿（valid=1, ready=0）
//             I <t_ns>          该周期为空闲（valid=0），即帧边界
// 说明    : 分帧、字段解析、校验和、FCS、序列号、BAG 间隔等检查由
//           scripts/check_frames.py 独立完成（与被测 RTL 无共享实现）。
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_tx;

    localparam CLK_NS = 20;                 // 50 MHz
    localparam N_VL   = 4;

    reg clk = 0;
    reg reset = 1;
    always #(CLK_NS/2) clk = ~clk;

    // ---------------- DUT ----------------
    reg          cfg_wr = 0;
    reg  [1:0]   cfg_vl = 0;
    reg  [2:0]   cfg_field = 0;
    reg  [207:0] cfg_data = 0;
    reg          enable = 0;
    reg          mac_tx_ready = 1;

    wire [7:0]   mac_tx_data;
    wire         mac_tx_valid;
    wire         busy, frame_done;
    wire [1:0]   done_vl;
    wire [15:0]  frame_len, dbg_ip_ck, dbg_udp_ck;
    wire [31:0]  dbg_fcs;
    wire [15:0]  txcnt;

    afdx_tx_path #(.N_VL(N_VL), .VW(2), .CW(32), .IFG_CYCLES(16)) dut (
        .clk(clk), .reset(reset),
        .cfg_wr(cfg_wr), .cfg_vl(cfg_vl), .cfg_field(cfg_field), .cfg_data(cfg_data),
        .enable(enable),
        .mac_tx_data(mac_tx_data), .mac_tx_valid(mac_tx_valid), .mac_tx_ready(mac_tx_ready),
        .busy(busy), .frame_done(frame_done), .done_vl(done_vl), .frame_len(frame_len),
        .dbg_ip_ck(dbg_ip_ck), .dbg_udp_ck(dbg_udp_ck), .dbg_fcs(dbg_fcs),
        .tx_frame_cnt(txcnt)
    );

    // ---------------- 配置任务 ----------------
    task cfg_ident;
        input [1:0]  vl;
        input [15:0] vlid;
        input [47:0] dmac, smac;
        input [31:0] dip, sip;
        input [15:0] dport, sport;
        begin
            @(negedge clk);
            cfg_vl    = vl;
            cfg_field = 3'd0;
            cfg_data  = {dmac, smac, dip, sip, dport, sport, vlid};
            cfg_wr    = 1'b1;
            @(negedge clk);
            cfg_wr    = 1'b0;
        end
    endtask

    task cfg_bag;
        input [1:0]  vl;
        input [31:0] b;
        begin
            @(negedge clk);
            cfg_vl = vl; cfg_field = 3'd1; cfg_data = {176'h0, b};
            cfg_wr = 1'b1; @(negedge clk); cfg_wr = 1'b0;
        end
    endtask

    task cfg_len;
        input [1:0]  vl;
        input [10:0] l;
        begin
            @(negedge clk);
            cfg_vl = vl; cfg_field = 3'd2; cfg_data = {197'h0, l};
            cfg_wr = 1'b1; @(negedge clk); cfg_wr = 1'b0;
        end
    endtask

    task cfg_en;
        input [1:0] vl;
        input       e;
        begin
            @(negedge clk);
            cfg_vl = vl; cfg_field = 3'd3; cfg_data = {207'h0, e};
            cfg_wr = 1'b1; @(negedge clk); cfg_wr = 1'b0;
        end
    endtask

    // ---------------- MAC 总线逐周期记录 ----------------
    integer         fout;
    reg [8*256-1:0] out_file;
    integer         n_byte, n_stall, n_idle, n_frame;
    reg             prev_valid;
    integer         nframe_max;
    integer         i, v;

    always @(posedge clk) begin
        if (!reset && fout != 0) begin
            if (mac_tx_valid && mac_tx_ready) begin
                $fwrite(fout, "B %0d %02x\n", $time, mac_tx_data);
                n_byte = n_byte + 1;
            end else if (mac_tx_valid) begin
                $fwrite(fout, "S %0d\n", $time);
                n_stall = n_stall + 1;
            end else begin
                if (prev_valid) $fwrite(fout, "I %0d\n", $time);
                n_idle = n_idle + 1;
            end
            // 帧计数：由"空闲 -> 有字节"的跳变计数
            if (mac_tx_valid && !prev_valid) n_frame = n_frame + 1;
            prev_valid <= mac_tx_valid;
        end
    end

    // ---------------- 主流程 ----------------
    initial begin
        n_byte = 0; n_stall = 0; n_idle = 0; n_frame = 0; prev_valid = 1'b0;
        fout = 0;

        if (!$value$plusargs("OUT=%s", out_file)) begin
            $display("[FAIL] 未指定 +OUT=<总线记录文件>");
            $finish;
        end
        if (!$value$plusargs("NFRAME=%d", nframe_max)) nframe_max = 12;

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        fout = $fopen(out_file, "w");
        if (fout == 0) begin $display("[FAIL] 无法打开输出文件"); $finish; end
        $display("[INFO] AFDX 发送通路测试开始 (CLK=%0dns, 目标帧数=%0d)", CLK_NS, nframe_max);

        // ---- 配置 3 个发送 VL ----
        // VL0: VLID 0x1001, BAG=2000  周期(40us),  功能数据 32 字节   -> 帧长 81   约 16.2 Mbps
        // VL1: VLID 0x1002, BAG=12000 周期(240us), 功能数据 1468 字节 -> 帧长 1517 约 50.6 Mbps
        // VL2: VLID 0x1003, BAG=6000  周期(120us), 功能数据 0 字节    -> 帧长 64   约  4.3 Mbps
        // 三条 VL 合计约 71 Mbps < 100 Mbps，链路不超订（否则抖动会被人为放大）
        cfg_ident(2'd0, 16'h1001, 48'h030000000000, 48'h020000000101,
                  32'h0A000001, 32'h0A000101, 16'h2001, 16'h1001);
        cfg_bag  (2'd0, 32'd2000);
        cfg_len  (2'd0, 11'd32);

        cfg_ident(2'd1, 16'h1002, 48'h030000000000, 48'h020000000101,
                  32'h0A000002, 32'h0A000101, 16'h2002, 16'h1001);
        cfg_bag  (2'd1, 32'd12000);
        cfg_len  (2'd1, 11'd1468);

        cfg_ident(2'd2, 16'h1003, 48'h030000000000, 48'h020000000101,
                  32'h0A000003, 32'h0A000101, 16'h2003, 16'h1001);
        cfg_bag  (2'd2, 32'd6000);
        cfg_len  (2'd2, 11'd0);

        cfg_en   (2'd0, 1'b1);
        cfg_en   (2'd1, 1'b1);
        cfg_en   (2'd2, 1'b1);

        repeat (4) @(posedge clk);
        enable = 1;

        // 等到帧数达标，并且总线回到空闲（保证最后一帧完整记录）
        wait (n_frame >= nframe_max);
        wait (!mac_tx_valid && !busy);
        repeat (60) @(posedge clk);

        $fclose(fout);
        fout = 0;

        $display("");
        $display("==================== 发送通路测试汇总 ====================");
        $display("发送帧数          = %0d", n_frame);
        $display("总线传输字节数    = %0d", n_byte);
        $display("背压停顿时钟数    = %0d", n_stall);
        $display("空闲时钟数        = %0d", n_idle);
        $display("总线记录文件      = %0s", out_file);
        $display("说明: 逐字段/校验和/序列号/BAG 检查见 check_frames.py");
        $display("RESULT: BUSLOG_DONE");
        $display("=========================================================");
        $finish;
    end

    // ---------------- 背压注入（独立进程） ----------------
    // 每 13 个时钟拉低 tx_ready 3 个时钟：验证背压期间帧内不产生空隙
    integer bp_cnt = 0;
    always @(posedge clk) begin
        if (!reset) begin
            bp_cnt = bp_cnt + 1;
            if ((bp_cnt % 13) == 0)      mac_tx_ready = 1'b0;
            else if ((bp_cnt % 13) == 3) mac_tx_ready = 1'b1;
        end
    end

    // ---------------- 全局超时保护 ----------------
    initial begin
        #4_000_000;
        $display("[WARN] 仿真超时: 已发送帧数=%0d", n_frame);
        $display("RESULT: TIMEOUT");
        $finish;
    end

    // ---------------- 可选状态跟踪（+TRACE） ----------------
    reg [4:0] prev_st = 5'h1f;
    always @(posedge clk) begin
        if ($test$plusargs("TRACE") && (dut.u_ftx.state !== prev_st)) begin
            $display("t=%0t state %0d -> %0d cnt=%0d v=%b r=%b",
                     $time, prev_st, dut.u_ftx.state, dut.u_ftx.cnt,
                     mac_tx_valid, mac_tx_ready);
            prev_st = dut.u_ftx.state;
        end
    end

    // ---------------- 可选：UDP 校验和喂入字节记录（+CKDUMP=<file>） ----------------
    // ---------------- 可选：调度器内部观察（+SCHED） ----------------
    always @(posedge clk) begin
        if ($test$plusargs("SCHED")) begin
            if (dut.u_sched.grant)
                $display("t=%0t GRANT vl=%0d scan=%0d fifo=%0d",
                         $time, dut.u_sched.grant_vl, dut.u_sched.scan_addr,
                         dut.u_sched.fifo_count);
            if (dut.u_sched.start_ack)
                $display("t=%0t START vl=%0d bag=%0d",
                         $time, dut.u_sched.start_vl, dut.u_sched.start_bag);
        end
    end

    integer      fck;
    reg [8*256-1:0] ck_file;
    initial begin
        if ($value$plusargs("CKDUMP=%s", ck_file)) begin
            fck = $fopen(ck_file, "w");
            if (fck != 0) begin
                forever begin
                    @(posedge clk);
                    if (dut.u_ftx.ck_ud_en)
                        $fwrite(fck, "%02x st=%0d ps=%0d cnt=%0d\n",
                                dut.u_ftx.ck_ud_din, dut.u_ftx.state,
                                dut.u_ftx.ps_i, dut.u_ftx.cnt);
                end
            end
        end
    end

endmodule
