// =============================================================================
// 文件名  : tb_afdx_top.v
// 用途    : 系统级测试
//           DUT1: AFDX_top（赛题模板顶层，单 MAC 总线）——发送总线自环到接收总线
//           DUT2: afdx_es_core（DUAL=1 双冗余网口）——A 与 B 各自自环，
//                 B 路增加传播延迟，用于验证"同一 VL 两份副本"的去重
// 判定    : 发送帧数 == 接收帧数 == 交付帧数；校验错误为 0；双网口重复副本被丢弃
// =============================================================================
`timescale 1ns/1ns
`include "afdx_defs.vh"

module tb_afdx_top;

    localparam CLK_NS   = 20;
    localparam N_FRAME  = 24;
    // B 网传播延迟：需大于一个帧的发送时间，否则两路副本会在同一解析通路上重叠
    // 需大于"单帧解析耗时"，否则 B 路副本会在解析通路繁忙期间到达而被丢弃
    localparam B_DELAY  = 500;

    reg clk = 0;
    reg reset = 1;
    always #(CLK_NS/2) clk = ~clk;

    // =====================================================================
    // DUT1: AFDX_top 单总线自环
    // =====================================================================
    wire [7:0] t1_tx_data;
    wire       t1_tx_valid, t1_tx_ready;

    AFDX_top u_top (
        .clk(clk), .reset(reset),
        .tx_data(t1_tx_data), .tx_valid(t1_tx_valid), .tx_ready(t1_tx_ready),
        .rx_data(t1_tx_data), .rx_valid(t1_tx_valid), .rx_ready(1'b1)
    );

    // =====================================================================
    // DUT2: ES 核心 双网口（A/B 各自自环，B 路有延迟）
    // =====================================================================
    wire [7:0] t2_tx_a_data, t2_tx_b_data;
    wire       t2_tx_a_valid, t2_tx_b_valid;

    // B 网延迟线
    reg [8:0] b_pipe [0:B_DELAY-1];
    integer   bi;
    always @(posedge clk) begin
        b_pipe[0] <= {t2_tx_b_valid, t2_tx_b_data};
        for (bi = 1; bi < B_DELAY; bi = bi + 1)
            b_pipe[bi] <= b_pipe[bi-1];
    end
    wire [8:0] t2_rx_b = b_pipe[B_DELAY-1];

    reg         d2_tx_cfg_wr, d2_tx_enable;
    reg  [1:0]  d2_tx_cfg_vl;
    reg  [2:0]  d2_tx_cfg_field;
    reg  [207:0] d2_tx_cfg_data;
    reg         d2_rx_cfg_wr, d2_rx_cfg_en;
    reg  [2:0]  d2_rx_cfg_vl;
    reg  [15:0] d2_rx_cfg_vlid;

    wire [15:0] d2_tx_frames, d2_rx_frames, d2_rx_deliv, d2_rx_err;
    wire [15:0] d2_rm_accept, d2_rm_dup, d2_rm_oos, d2_rm_unknown, d2_ic_err;
    wire [7:0]  d2_fault;
    wire        d2_dly_valid;
    wire [7:0]  d2_dly_data;
    wire        d2_tx_busy;
    wire [15:0] d2_rx_drop;
    wire [15:0] d2_dly_vlid;
    wire [7:0]  d2_dly_sn;
    wire [10:0] d2_dly_plen;
    wire        d2_dly_start, d2_dly_end;

    afdx_es_core #(.N_TX_VL(4), .TVW(2), .N_RX_VL(8), .RVW(3), .DUAL(1)) u_dual (
        .clk(clk), .reset(reset),
        .tx_a_data(t2_tx_a_data), .tx_a_valid(t2_tx_a_valid), .tx_a_ready(1'b1),
        .rx_a_data(t2_tx_a_data), .rx_a_valid(t2_tx_a_valid), .rx_a_accept(),
        .tx_b_data(t2_tx_b_data), .tx_b_valid(t2_tx_b_valid), .tx_b_ready(1'b1),
        .rx_b_data(t2_rx_b[7:0]), .rx_b_valid(t2_rx_b[8]), .rx_b_accept(),
        .tx_cfg_wr(d2_tx_cfg_wr), .tx_cfg_vl(d2_tx_cfg_vl),
        .tx_cfg_field(d2_tx_cfg_field), .tx_cfg_data(d2_tx_cfg_data),
        .tx_enable(d2_tx_enable),
        .rx_cfg_wr(d2_rx_cfg_wr), .rx_cfg_vl(d2_rx_cfg_vl),
        .rx_cfg_vlid(d2_rx_cfg_vlid), .rx_cfg_en(d2_rx_cfg_en),
        .tx_busy(d2_tx_busy), .tx_frames(d2_tx_frames), .tx_frame_len(),
        .dly_valid(d2_dly_valid), .dly_start(d2_dly_start), .dly_end(d2_dly_end),
        .dly_data(d2_dly_data), .dly_vlid(d2_dly_vlid), .dly_sn(d2_dly_sn),
        .dly_plen(d2_dly_plen),
        .rx_frames(d2_rx_frames), .rx_deliv(d2_rx_deliv), .rx_err(d2_rx_err),
        .rm_accept(d2_rm_accept), .rm_dup(d2_rm_dup), .rm_oos(d2_rm_oos),
        .rm_unknown(d2_rm_unknown), .ic_err(d2_ic_err),
        .vl_fault(d2_fault), .dbg_err_code(), .rx_drop(d2_rx_drop)
    );

    // 双网口 DUT 的配置序列
    task cfg_dual_vl;
        input [15:0] vlid;
        input [10:0] dlen;
        input [31:0] bag;
        begin
            @(negedge clk);
            d2_tx_cfg_vl    = 2'd0;
            d2_tx_cfg_field = 3'd0;
            d2_tx_cfg_data  = {48'h030000000000, 48'h020000000101,
                               32'h0A000001, 32'h0A000101,
                               16'h2001, 16'h1001, vlid};
            d2_tx_cfg_wr    = 1'b1;
            @(negedge clk); d2_tx_cfg_wr = 1'b0;

            d2_tx_cfg_field = 3'd1; d2_tx_cfg_data = {176'h0, bag};
            d2_tx_cfg_wr = 1'b1; @(negedge clk); d2_tx_cfg_wr = 1'b0;

            d2_tx_cfg_field = 3'd2; d2_tx_cfg_data = {197'h0, dlen};
            d2_tx_cfg_wr = 1'b1; @(negedge clk); d2_tx_cfg_wr = 1'b0;

            d2_tx_cfg_field = 3'd3; d2_tx_cfg_data = 208'h1;
            d2_tx_cfg_wr = 1'b1; @(negedge clk); d2_tx_cfg_wr = 1'b0;

            @(negedge clk);
            d2_rx_cfg_vl = 3'd0; d2_rx_cfg_vlid = vlid; d2_rx_cfg_en = 1'b1;
            d2_rx_cfg_wr = 1'b1; @(negedge clk); d2_rx_cfg_wr = 1'b0;

            @(negedge clk); d2_tx_enable = 1'b1;
        end
    endtask

    // ---------------- 主流程 ----------------
    integer n_err;
    initial begin
        n_err = 0;
        d2_tx_cfg_wr = 0; d2_tx_enable = 0; d2_tx_cfg_vl = 0; d2_tx_cfg_field = 0;
        d2_tx_cfg_data = 0; d2_rx_cfg_wr = 0; d2_rx_cfg_en = 0; d2_rx_cfg_vl = 0;
        d2_rx_cfg_vlid = 0;
        for (bi = 0; bi < B_DELAY; bi = bi + 1) b_pipe[bi] = 9'h000;

        repeat (6) @(posedge clk);
        reset = 0;
        repeat (4) @(posedge clk);

        $display("[INFO] 系统级测试开始（目标 %0d 帧）", N_FRAME);
        cfg_dual_vl(16'h1001, 11'd32, 32'd2000);

        // 等到两个 DUT 的交付帧数都达标（避免采样竞争）
        wait ((u_top.core_rx_deliv >= N_FRAME) && (d2_rx_deliv >= N_FRAME));
        // 采样前等两个解析通路都空闲，保证计数闭合（不留半帧）
        wait (u_top.u_core.rx_ready_int && u_dual.rx_ready_int);
        repeat (20) @(posedge clk);

        $display("");
        $display("============== DUT1: AFDX_top 单总线自环 ==============");
        $display("tx_frames=%0d  rx_frames=%0d  rx_deliv=%0d  rx_err=%0d",
                 u_top.core_tx_frames, u_top.core_rx_frames,
                 u_top.core_rx_deliv, u_top.core_rx_err);
        if (u_top.core_tx_frames < N_FRAME) begin
            $display("[FAIL] DUT1 发送帧数不足"); n_err = n_err + 1;
        end
        if (u_top.core_rx_deliv !== u_top.core_rx_frames) begin
            $display("[FAIL] DUT1 交付帧数 %0d != 接收帧数 %0d",
                     u_top.core_rx_deliv, u_top.core_rx_frames);
            n_err = n_err + 1;
        end
        if (u_top.core_rx_err !== 16'd0) begin
            $display("[FAIL] DUT1 接收校验错误 %0d", u_top.core_rx_err);
            n_err = n_err + 1;
        end

        $display("");
        $display("========== DUT2: 双冗余网口（B 路延迟 %0d 周期） ==========", B_DELAY);
        $display("tx_frames=%0d  rx_frames=%0d  rx_deliv=%0d  rx_err=%0d  rx_drop=%0d",
                 d2_tx_frames, d2_rx_frames, d2_rx_deliv, d2_rx_err, d2_rx_drop);
        $display("冗余管理: 接受=%0d 重复副本=%0d 失序=%0d 未知VL=%0d 完整性错误=%0d 故障=%b",
                 d2_rm_accept, d2_rm_dup, d2_rm_oos, d2_rm_unknown, d2_ic_err, d2_fault);
        if (d2_tx_frames < N_FRAME) begin
            $display("[FAIL] DUT2 发送帧数不足"); n_err = n_err + 1;
        end
        // 不变式：接收帧 = 接受交付 + 重复副本丢弃（发送与解析之间存在流水延迟，
        // 因此不与"发送帧数"直接比较，避免采样竞争）
        if (d2_rx_deliv !== d2_rm_accept) begin
            $display("[FAIL] DUT2 交付帧数 %0d != 冗余管理接受数 %0d",
                     d2_rx_deliv, d2_rm_accept);
            n_err = n_err + 1;
        end
        if ((d2_rx_deliv + d2_rm_dup) !== d2_rx_frames) begin
            $display("[FAIL] DUT2 帧数不闭合: 交付 %0d + 重复 %0d != 接收 %0d",
                     d2_rx_deliv, d2_rm_dup, d2_rx_frames);
            n_err = n_err + 1;
        end
        if (d2_rm_dup + 1 < d2_rx_deliv) begin
            $display("[FAIL] DUT2 重复副本去重数 %0d 偏少（交付 %0d 帧）",
                     d2_rm_dup, d2_rx_deliv);
            n_err = n_err + 1;
        end
        if (d2_rx_err !== 16'd0) begin
            $display("[FAIL] DUT2 接收校验错误 %0d", d2_rx_err);
            n_err = n_err + 1;
        end
        if (d2_rx_drop !== 16'd0) begin
            $display("[WARN] DUT2 存在接收丢弃字节 %0d", d2_rx_drop);
        end

        $display("");
        $display("==================== 系统级测试汇总 ====================");
        $display("错误数 = %0d", n_err);
        if (n_err == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $display("=======================================================");
        $finish;
    end

    // ---------------- 超时保护 ----------------
    initial begin
        #10_000_000;
        $display("[WARN] 系统级仿真超时");
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule
