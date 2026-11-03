// =============================================================================
// 文件名  : afdx_top.v
// 模块    : AFDX_top
// 赛题    : 全国大学生嵌入式芯片与系统设计竞赛'2026 FPGA 创新设计赛道
//           选题一 基于以太网 MAC 总线实现 AFDX
//
// 说明    : 顶层端口严格采用赛题指南给定的模板（名称/位宽/方向不得改动）。
//
// MAC 总线接口约定（8 位）：
//   发送 tx_data/tx_valid ：本端输出，帧内连续、帧间留空闲（空闲即帧边界）
//   tx_ready（输出）      ：本端"可发送/空闲"状态指示（帧组装器空闲=1）
//   rx_data/rx_valid（输入）：对端送来的帧字节
//   rx_ready（输入）      ：外部 MAC 的数据有效限定（与 rx_valid 相与后采样）
// 注：赛题模板中 tx_ready 为输出、rx_ready 为输入，与 AXI-stream 习惯相反，
//     本工程按上述语义实现；如需改为反压语义，仅需调整本文件的端口连接。
//
// 内部：ES 核心（发送调度 + 帧组装 + 接收解析 + 冗余管理 + 完整性检查），
//       并在上电后由内部配置序列写入默认 VL 配置（VLID 0x1001）。
// =============================================================================
`include "afdx_defs.vh"

module AFDX_top (
    input  wire       clk,        // 时钟信号
    input  wire       reset,      // 复位信号
    output wire [7:0] tx_data,    // 发送数据
    input  wire [7:0] rx_data,    // 接收数据
    output wire       tx_valid,   // 发送数据有效指示
    input  wire       rx_valid,   // 接收数据有效指示
    output wire       tx_ready,   // 发送数据准备好指示
    input  wire       rx_ready    // 接收数据准备好指示
);

    // ------------------------------------------------------------------
    // 上电配置序列：写入默认发送 VL 与接收 VL
    //   TX VL0: VLID 0x1001, BAG 2000 周期, 功能数据 32 字节
    //   RX VL0: VLID 0x1001
    // ------------------------------------------------------------------
    reg [3:0]    cfg_step;
    reg          tx_cfg_wr;
    reg [4:0]    tx_cfg_vl;
    reg [2:0]    tx_cfg_field;
    reg [207:0]  tx_cfg_data;
    reg          rx_cfg_wr;
    reg [5:0]    rx_cfg_vl;
    reg [15:0]   rx_cfg_vlid;
    reg          rx_cfg_en;
    reg          tx_enable;

    always @(posedge clk) begin
        if (reset) begin
            cfg_step    <= 4'd0;
            tx_cfg_wr   <= 1'b0;
            tx_cfg_vl   <= 5'd0;
            tx_cfg_field<= 3'd0;
            tx_cfg_data <= 208'h0;
            rx_cfg_wr   <= 1'b0;
            rx_cfg_vl   <= 6'd0;
            rx_cfg_vlid <= 16'h0;
            rx_cfg_en   <= 1'b0;
            tx_enable   <= 1'b0;
        end else begin
            tx_cfg_wr <= 1'b0;
            rx_cfg_wr <= 1'b0;
            case (cfg_step)
            4'd0: begin   // 发送 VL 标识：MAC/IP/UDP 端口/VLID
                tx_cfg_vl    <= 5'd0;
                tx_cfg_field <= 3'd0;
                tx_cfg_data  <= {48'h030000000000, 48'h020000000101,
                                 32'h0A000001, 32'h0A000101,
                                 16'h2001, 16'h1001, 16'h1001};
                tx_cfg_wr    <= 1'b1;
                cfg_step     <= 4'd1;
            end
            4'd1: begin   // 发送 BAG（时钟周期数）
                tx_cfg_field <= 3'd1;
                tx_cfg_data  <= {176'h0, 32'd2000};
                tx_cfg_wr    <= 1'b1;
                cfg_step     <= 4'd2;
            end
            4'd2: begin   // 功能数据长度
                tx_cfg_field <= 3'd2;
                tx_cfg_data  <= {197'h0, 11'd32};
                tx_cfg_wr    <= 1'b1;
                cfg_step     <= 4'd3;
            end
            4'd3: begin   // 发送使能
                tx_cfg_field <= 3'd3;
                tx_cfg_data  <= 208'h1;
                tx_cfg_wr    <= 1'b1;
                cfg_step     <= 4'd4;
            end
            4'd4: begin   // 接收 VL0 = 0x1001
                rx_cfg_vl   <= 6'd0;
                rx_cfg_vlid <= 16'h1001;
                rx_cfg_en   <= 1'b1;
                rx_cfg_wr   <= 1'b1;
                cfg_step    <= 4'd5;
            end
            4'd5: begin   // 使能调度
                tx_enable <= 1'b1;
                cfg_step  <= 4'd6;
            end
            default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // ES 核心（单 MAC 总线配置）
    // ------------------------------------------------------------------
    wire        core_tx_busy;
    wire [15:0] core_tx_frames, core_rx_frames, core_rx_deliv, core_rx_err;

    afdx_es_core #(.N_TX_VL(32), .TVW(5), .N_RX_VL(64), .RVW(6), .DUAL(0),
                   .EN_MGMT(1)) u_core (
        .clk(clk), .reset(reset),
        .tx_a_data(tx_data), .tx_a_valid(tx_valid), .tx_a_ready(1'b1),
        .rx_a_data(rx_data), .rx_a_valid(rx_valid & rx_ready), .rx_a_accept(),
        .tx_b_data(), .tx_b_valid(), .tx_b_ready(1'b1),
        .rx_b_data(8'h00), .rx_b_valid(1'b0), .rx_b_accept(),
        .tx_cfg_wr(tx_cfg_wr), .tx_cfg_vl(tx_cfg_vl),
        .tx_cfg_field(tx_cfg_field), .tx_cfg_data(tx_cfg_data),
        .tx_enable(tx_enable),
        .rx_cfg_wr(rx_cfg_wr), .rx_cfg_vl(rx_cfg_vl),
        .rx_cfg_vlid(rx_cfg_vlid), .rx_cfg_en(rx_cfg_en),
        .tx_busy(core_tx_busy), .tx_frames(core_tx_frames),
        .tx_frame_len(), .dly_valid(), .dly_start(), .dly_end(), .dly_data(),
        .dly_vlid(), .dly_sn(), .dly_plen(),
        .rx_frames(core_rx_frames), .rx_deliv(core_rx_deliv), .rx_err(core_rx_err),
        .rm_accept(), .rm_dup(), .rm_oos(), .rm_unknown(), .ic_err(),
        .vl_fault(), .dbg_err_code(), .rx_drop()
    );

    // 发送侧"准备好"指示：帧组装器空闲即表示可发送下一帧
    assign tx_ready = ~core_tx_busy;

endmodule
