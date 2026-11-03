// =============================================================================
// 文件名  : afdx_rm_rx.v
// 模块    : afdx_rm_rx
// 功能    : 接收侧冗余管理（Redundancy Management）与完整性检查（Integrity Check）
//
// 判定规则（每个接收 VL 独立维护状态）：
//   1) 首次收到该 VL        -> 接受，记录序列号
//   2) SN == 上次接受值      -> 重复副本（A/B 双网的另一份）-> 丢弃并计数
//   3) SN == 上次值 + 1      -> 正常新帧 -> 接受
//   4) 其他（跳变/失序）      -> 完整性错误计数；若按模 256 前向距离 < 128
//                              视为"更新的帧" -> 接受（先到有效者优先，可恢复丢帧）
//                              否则视为过期帧 -> 丢弃并计数
// 完整性检查：每个 VL 维护最近 16 帧的错误窗口，窗口内错误数 >= 阈值判定该 VL 故障
// 时序    : meta_valid 为 1 拍脉冲，本模块在该拍组合判定并寄存器化，
//           解析器在下一拍读取 accept
// =============================================================================
`include "afdx_defs.vh"

module afdx_rm_rx #(
    parameter N_VL      = 8,
    parameter VW        = 3,
    parameter IC_WINDOW = 16,
    parameter IC_THRESH = 3
) (
    input  wire            clk,
    input  wire            reset,
    // ---- 接收 VL 配置（VLID 表） ----
    input  wire            cfg_wr,
    input  wire [VW-1:0]   cfg_vl,
    input  wire [15:0]     cfg_vlid,
    input  wire            cfg_en,
    // ---- 解析器元数据 ----
    input  wire            meta_valid,
    input  wire [15:0]     meta_vlid,
    input  wire [7:0]      meta_sn,
    output reg             accept,        // 判定结果（meta_valid 之后 1 拍有效）
    // ---- 统计与状态 ----
    output reg  [15:0]     cnt_accept,
    output reg  [15:0]     cnt_dup,
    output reg  [15:0]     cnt_oos,
    output reg  [15:0]     cnt_unknown,
    output wire [N_VL-1:0] fault_vec,
    output reg  [15:0]     cnt_ic_err,
    output reg  [15:0]     rm_vlid_dbg,
    output reg  [VW-1:0]   rm_idx_dbg
);

    reg [15:0]         vlid_ram [0:N_VL-1];
    reg [N_VL-1:0]     en_ram;
    reg [7:0]          last_sn  [0:N_VL-1];
    reg [N_VL-1:0]     have;
    reg [IC_WINDOW-1:0] ic_win  [0:N_VL-1];
    reg [N_VL-1:0]     fault;

    integer   i;
    reg [VW-1:0] m_idx;
    reg          m_found;

    // ---------------- 组合查找：按 VLID 匹配接收 VL ----------------
    always @(*) begin
        m_found = 1'b0;
        m_idx   = {VW{1'b0}};
        for (i = N_VL-1; i >= 0; i = i - 1) begin
            if (vlid_ram[i] == meta_vlid) begin
                m_found = 1'b1;
                m_idx   = i[VW-1:0];
            end
        end
    end

    // ---------------- 组合判定 ----------------
    wire [7:0] last_sn_w = last_sn[m_idx];
    wire [7:0] next_sn_w = (last_sn_w == `SN_MAX) ? `SN_MIN : (last_sn_w + 8'd1);
    wire [7:0] dist_w    = meta_sn - last_sn_w;
    wire vl_ok_w   = m_found && en_ram[m_idx];
    wire is_dup_w  = have[m_idx] && (meta_sn == last_sn_w);
    wire is_next_w = have[m_idx] && (meta_sn == next_sn_w);
    wire is_new_w  = have[m_idx] && (dist_w != 8'd0) && (dist_w < 8'd128);
    wire accept_w  = vl_ok_w && (!have[m_idx] || is_next_w || is_new_w);
    // 注意：首个帧（have=0）不算失序；失序仅针对已建立序列的 VL
    wire oos_w     = vl_ok_w && have[m_idx] && !is_dup_w && !is_next_w;
    wire err_evt_w = oos_w;      // 计入完整性检查窗口

    // ---------------- 窗口内错误计数（popcount） ----------------
    reg [4:0] pc;
    always @(*) begin
        pc = 5'd0;
        for (i = 0; i < IC_WINDOW; i = i + 1)
            pc = pc + ic_win[m_idx][i];
    end

    // ---------------- 状态更新 ----------------
    always @(posedge clk) begin
        if (reset) begin
            accept       <= 1'b0;
            cnt_accept   <= 16'd0;
            cnt_dup      <= 16'd0;
            cnt_oos      <= 16'd0;
            cnt_unknown  <= 16'd0;
            cnt_ic_err   <= 16'd0;
            rm_vlid_dbg  <= 16'd0;
            rm_idx_dbg   <= {VW{1'b0}};
            en_ram       <= {N_VL{1'b0}};
            have         <= {N_VL{1'b0}};
            fault        <= {N_VL{1'b0}};
            for (i = 0; i < N_VL; i = i + 1) begin
                vlid_ram[i] <= 16'hFFFF;
                last_sn[i]  <= 8'd0;
                ic_win[i]   <= {IC_WINDOW{1'b0}};
            end
        end else begin
            // 配置写
            if (cfg_wr) begin
                vlid_ram[cfg_vl] <= cfg_vlid;
                en_ram[cfg_vl]   <= cfg_en;
            end

            // 元数据判定
            // accept 保持到下一次 meta_valid 为止（解析器需在整个载荷交付期间读取）
            if (meta_valid) begin
                accept      <= accept_w;
                rm_vlid_dbg <= meta_vlid;
                rm_idx_dbg  <= m_idx;

                if (!m_found || !en_ram[m_idx]) begin
                    cnt_unknown <= cnt_unknown + 16'd1;
                end else if (is_dup_w) begin
                    cnt_dup <= cnt_dup + 16'd1;
                end else if (accept_w) begin
                    cnt_accept <= cnt_accept + 16'd1;
                    if (oos_w) cnt_oos <= cnt_oos + 16'd1;
                    last_sn[m_idx] <= meta_sn;
                    have[m_idx]    <= 1'b1;
                    if (err_evt_w) begin
                        cnt_ic_err     <= cnt_ic_err + 16'd1;
                        ic_win[m_idx]  <= {ic_win[m_idx][IC_WINDOW-2:0], 1'b1};
                    end else begin
                        ic_win[m_idx]  <= {ic_win[m_idx][IC_WINDOW-2:0], 1'b0};
                    end
                end else begin
                    // 过期帧：丢弃并计入完整性错误
                    cnt_dup        <= cnt_dup + 16'd1;
                    cnt_ic_err     <= cnt_ic_err + 16'd1;
                    ic_win[m_idx]  <= {ic_win[m_idx][IC_WINDOW-2:0], 1'b1};
                end

                // 完整性检查：窗口内错误数达阈值 -> 判定该 VL 故障
                if (m_found && ((pc + (err_evt_w ? 5'd1 : 5'd0)) >= IC_THRESH))
                    fault[m_idx] <= 1'b1;
            end
        end
    end

    assign fault_vec = fault;

endmodule
