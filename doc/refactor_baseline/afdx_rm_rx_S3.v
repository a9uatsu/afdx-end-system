// =============================================================================
// 文件名  : afdx_rm_rx.v
// 模块    : afdx_rm_rx
// 功能    : 接收冗余管理 + 完整性检查（VLID 表二分查找 + 状态 RAM）
//
// VLID 配置表按索引升序写入，运行时只支持在该有序表上二分查找。
// 每帧流程：VLID 二分查找 -> 状态 RAM 读 -> SN 判定 -> 状态读改写。
// meta_valid 后经 rm_ready 通知解析器判定完成，accept 保持到下一次判定。
// =============================================================================
`include "afdx_defs.vh"

// 标准单写口/同步读状态 RAM；独立模块便于 eLinx 推断 M4K。
module afdx_rm_state_ram #(
    parameter N_VL = 4096,
    parameter AW   = 12
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [25:0]   wdata,
    input  wire [AW-1:0] raddr,
    output reg  [25:0]   q
);
    (* ramstyle = "M4K", no_rw_check *) reg [25:0] mem [0:N_VL-1];
    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        q <= mem[raddr];
    end
endmodule

module afdx_rm_rx #(
    parameter N_VL      = 4096,
    parameter VW        = 12,
    parameter SEARCH_W  = 13,
    parameter IC_WINDOW = 16,
    parameter IC_THRESH = 3
) (
    input  wire            clk,
    input  wire            reset,
    // ---- 接收 VL 配置：必须按 cfg_vl 升序写 VLID ----
    input  wire            cfg_wr,
    input  wire [VW-1:0]   cfg_vl,
    input  wire [15:0]     cfg_vlid,
    input  wire            cfg_en,
    // ---- 解析器元数据 ----
    input  wire            meta_valid,
    input  wire [15:0]     meta_vlid,
    input  wire [7:0]      meta_sn,
    output reg             accept,
    output reg             rm_ready,      // 判定完成脉冲
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

    localparam [3:0] S_IDLE        = 4'd0,
                     S_SEARCH_REQ  = 4'd1,
                     S_SEARCH_WAIT = 4'd2,
                     S_SEARCH_CMP  = 4'd3,
                     S_CAND_REQ    = 4'd4,
                     S_CAND_WAIT   = 4'd5,
                     S_CAND_CMP    = 4'd6,
                     S_STATE_WAIT  = 4'd7,
                     S_STATE_CMP   = 4'd8,
                     S_HOLD        = 4'd9;

    // cfg_ram = {使能, VLID[15:0]}
    (* ramstyle = "M4K", no_rw_check *) reg [16:0] cfg_ram [0:N_VL-1];
    reg [16:0] cfg_q;
    reg [VW-1:0] cfg_raddr;

    // state_ram = {fault, ic_window[15:0], have, last_sn[7:0]}
    wire [25:0] state_q;
    reg         state_we;
    reg [VW-1:0] state_waddr;
    reg [25:0]  state_wdata;
    reg [VW-1:0] state_raddr;

    reg [N_VL-1:0] fault;
    reg [3:0] st;
    reg [15:0] m_vlid;
    reg [7:0]  m_sn;
    reg [15:0] lo, hi, mid;
    reg [4:0]  search_step;
    reg [VW-1:0] m_idx;
    reg        m_found;

    wire [7:0]  last_sn_w = state_q[7:0];
    wire        have_w    = state_q[8];
    wire [IC_WINDOW-1:0] ic_win_w = state_q[24:9];
    wire [7:0]  next_sn_w = (last_sn_w == `SN_MAX) ? `SN_MIN : (last_sn_w + 8'd1);
    wire [7:0]  dist_w    = m_sn - last_sn_w;
    wire        is_dup_w  = have_w && (m_sn == last_sn_w);
    wire        is_next_w = have_w && (m_sn == next_sn_w);
    wire        is_new_w  = have_w && (dist_w != 8'd0) && (dist_w < 8'd128);
    wire        accept_w  = !have_w || is_next_w || is_new_w;
    wire        oos_w     = have_w && !is_dup_w && !is_next_w;
    wire        err_evt_w = oos_w;

    reg [4:0] pc;
    integer i;
    always @(*) begin
        pc = 5'd0;
        for (i = 0; i < IC_WINDOW; i = i + 1)
            pc = pc + ic_win_w[i];
    end

    wire [IC_WINDOW-1:0] ic_new = {ic_win_w[IC_WINDOW-2:0], (err_evt_w ? 1'b1 : 1'b0)};
    wire fault_new = ((pc + (err_evt_w ? 5'd1 : 5'd0)) >= IC_THRESH);

    afdx_rm_state_ram #(.N_VL(N_VL), .AW(VW)) u_state_ram (
        .clk(clk), .we(state_we), .waddr(state_waddr), .wdata(state_wdata),
        .raddr(state_raddr), .q(state_q)
    );

    always @(posedge clk) begin
        if (reset) begin
            st           <= S_IDLE;
            accept       <= 1'b0;
            rm_ready     <= 1'b0;
            cnt_accept   <= 16'd0;
            cnt_dup      <= 16'd0;
            cnt_oos      <= 16'd0;
            cnt_unknown  <= 16'd0;
            cnt_ic_err   <= 16'd0;
            fault        <= {N_VL{1'b0}};
            rm_vlid_dbg  <= 16'd0;
            rm_idx_dbg   <= {VW{1'b0}};
            m_idx        <= {VW{1'b0}};
            m_found      <= 1'b0;
            lo           <= 16'd0;
            hi           <= 16'd0;
            mid          <= 16'd0;
            search_step  <= 5'd0;
        end else begin
            rm_ready <= 1'b0;
            state_we <= 1'b0;

            // 配置写口同时初始化对应状态记录。
            if (cfg_wr) begin
                cfg_ram[cfg_vl] <= {cfg_en, cfg_vlid};
                state_we        <= 1'b1;
                state_waddr     <= cfg_vl;
                state_wdata     <= 26'd0;
                fault[cfg_vl]   <= 1'b0;
            end

            // 同步读口：二分查找候选和状态记录分时复用。
            cfg_q   <= cfg_ram[cfg_raddr];

            case (st)
            S_IDLE: begin
                if (meta_valid) begin
                    m_vlid      <= meta_vlid;
                    m_sn        <= meta_sn;
                    rm_vlid_dbg <= meta_vlid;
                    lo          <= 16'd0;
                    hi          <= N_VL;
                    search_step <= 5'd0;
                    m_found     <= 1'b0;
                    accept      <= 1'b0;
                    st          <= S_SEARCH_REQ;
                end
            end

            S_SEARCH_REQ: begin
                if (lo >= hi) begin
                    st <= S_CAND_REQ;
                end else begin
                    mid       <= (lo + hi) >> 1;
                    cfg_raddr <= ((lo + hi) >> 1);
                    st        <= S_SEARCH_WAIT;
                end
            end

            S_SEARCH_WAIT: begin
                st <= S_SEARCH_CMP;
            end

            S_SEARCH_CMP: begin
                if (cfg_q[15:0] < m_vlid)
                    lo <= mid + 16'd1;
                else
                    hi <= mid;

                if (search_step == (SEARCH_W-1)) begin
                    search_step <= 5'd0;
                    st          <= S_CAND_REQ;
                end else begin
                    search_step <= search_step + 5'd1;
                    st          <= S_SEARCH_REQ;
                end
            end

            S_CAND_REQ: begin
                if (lo < N_VL) begin
                    cfg_raddr <= lo[VW-1:0];
                    st        <= S_CAND_WAIT;
                end else begin
                    cnt_unknown <= cnt_unknown + 16'd1;
                    rm_ready    <= 1'b1;
                    st          <= S_HOLD;
                end
            end

            S_CAND_WAIT: begin
                st <= S_CAND_CMP;
            end

            S_CAND_CMP: begin
                if (cfg_q[16] && (cfg_q[15:0] == m_vlid)) begin
                    m_found  <= 1'b1;
                    m_idx    <= lo[VW-1:0];
                    rm_idx_dbg <= lo[VW-1:0];
                    state_raddr <= lo[VW-1:0];
                    st       <= S_STATE_WAIT;
                end else begin
                    cnt_unknown <= cnt_unknown + 16'd1;
                    rm_ready    <= 1'b1;
                    st          <= S_HOLD;
                end
            end

            S_STATE_WAIT: begin
                st <= S_STATE_CMP;
            end

            S_STATE_CMP: begin
                accept   <= accept_w;
                rm_ready <= 1'b1;

                if (is_dup_w) begin
                    cnt_dup <= cnt_dup + 16'd1;
                end else if (accept_w) begin
                    cnt_accept <= cnt_accept + 16'd1;
                    if (oos_w) cnt_oos <= cnt_oos + 16'd1;
                    state_we    <= 1'b1;
                    state_waddr <= m_idx;
                    state_wdata <= {fault_new, ic_new, 1'b1, m_sn};
                    if (err_evt_w) begin
                        cnt_ic_err <= cnt_ic_err + 16'd1;
                        if (fault_new) fault[m_idx] <= 1'b1;
                    end else if (fault_new) begin
                        fault[m_idx] <= 1'b1;
                    end
                end else begin
                    cnt_dup    <= cnt_dup + 16'd1;
                    cnt_ic_err <= cnt_ic_err + 16'd1;
                    state_we    <= 1'b1;
                    state_waddr <= m_idx;
                    state_wdata <= {fault_new, ic_new, 1'b1, last_sn_w};
                    if (fault_new) fault[m_idx] <= 1'b1;
                end
                st <= S_HOLD;
            end

            S_HOLD: begin
                if (!meta_valid)
                    st <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

    assign fault_vec = fault;

endmodule
