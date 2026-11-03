// =============================================================================
// 文件名  : afdx_scheduler.v
// 模块    : afdx_scheduler
// 功能    : 128 VL BAG 后台扫描、就绪 FIFO 与轮询授权
//
// - 4 个 next_start bank 与配置表 bank 一一对应，每拍并行检查 4 个 VL；
// - 128 VL 一轮 32 拍（50 MHz 下 640 ns）；
// - 就绪 VL 压入 16 深 FIFO，消除轮询指针偶发跳拍造成的饿死；
// - 帧真正开始时写回 next_start = now + BAG。
// =============================================================================
`include "afdx_defs.vh"

module afdx_scheduler #(
    parameter N_VL = 128,
    parameter VW   = 7,
    parameter SW   = 5,
    parameter CW   = 32
) (
    input  wire               clk,
    input  wire               reset,
    input  wire               enable,
    input  wire [3:0]         scan_en,
    input  wire               scan_inhibit,
    output reg  [SW-1:0]      scan_addr,
    input  wire               start_ack,
    input  wire [VW-1:0]      start_vl,
    input  wire [CW-1:0]      start_bag,
    input  wire               allow_start,
    output reg                grant,
    output reg  [VW-1:0]      grant_vl
);

    localparam BANK_N = (N_VL + 3) / 4;

    (* ramstyle = "M4K", no_rw_check *) reg [CW-1:0] t_b0 [0:BANK_N-1];
    (* ramstyle = "M4K", no_rw_check *) reg [CW-1:0] t_b1 [0:BANK_N-1];
    (* ramstyle = "M4K", no_rw_check *) reg [CW-1:0] t_b2 [0:BANK_N-1];
    (* ramstyle = "M4K", no_rw_check *) reg [CW-1:0] t_b3 [0:BANK_N-1];
    reg [CW-1:0] q_t0, q_t1, q_t2, q_t3;

    reg [CW-1:0] now;
    reg [N_VL-1:0] armed;
    reg [N_VL-1:0] listed;
    reg [VW-1:0]   ready_fifo [0:15];
    reg [3:0]      fifo_wr, fifo_rd;
    reg [4:0]      fifo_count;
    reg [SW-1:0]   scan_idx_q;
    reg            scan_valid_q;
    reg            enable_q;

    integer j, enq_count, pop_now;
    reg [VW-1:0] id_w;
    reg [CW-1:0] q_sel;
    reg          ready_w;
    reg [3:0]    wr_slot;
    reg [CW-1:0] now_plus1;
    reg [SW-1:0] scan_next;

    wire [VW-1:0] bank_addr = start_vl >> 2;
    wire [1:0]    bank_sel  = start_vl[1:0];

    always @(posedge clk) begin
        if (reset) begin
            now          <= {CW{1'b0}};
            armed        <= {N_VL{1'b0}};
            listed       <= {N_VL{1'b0}};
            fifo_wr      <= 4'd0;
            fifo_rd      <= 4'd0;
            fifo_count   <= 5'd0;
            scan_addr    <= {SW{1'b0}};
            scan_idx_q   <= {SW{1'b0}};
            scan_valid_q <= 1'b0;
            grant        <= 1'b0;
            grant_vl     <= {VW{1'b0}};
            enable_q     <= 1'b0;
        end else begin
            now        <= now + {{(CW-1){1'b0}}, 1'b1};
            grant      <= 1'b0;
            now_plus1  = now + {{(CW-1){1'b0}}, 1'b1};
            pop_now    = 0;

            // next_start RAM 读口与扫描表同步；两个模块输出均在下一拍有效。
            q_t0 <= t_b0[scan_addr];
            q_t1 <= t_b1[scan_addr];
            q_t2 <= t_b2[scan_addr];
            q_t3 <= t_b3[scan_addr];

            if (scan_inhibit) begin
                scan_idx_q   <= scan_addr;
                scan_valid_q <= 1'b0;
            end else begin
                scan_idx_q   <= scan_addr;
                scan_valid_q <= 1'b1;
                scan_next    = scan_addr + {{(SW-1){1'b0}}, 1'b1};
                if (scan_next >= BANK_N)
                    scan_addr <= {SW{1'b0}};
                else
                    scan_addr <= scan_next;
            end

            // 帧真正开始：BAG 从此刻开始计时，并标记该 VL 已进入周期状态。
            if (start_ack) begin
                armed[start_vl] <= 1'b1;
                listed[start_vl] <= 1'b0;
                case (bank_sel)
                    2'd0: t_b0[bank_addr] <= now + start_bag;
                    2'd1: t_b1[bank_addr] <= now + start_bag;
                    2'd2: t_b2[bank_addr] <= now + start_bag;
                    default: t_b3[bank_addr] <= now + start_bag;
                endcase
            end

            // 授权：从 FIFO 头部取一个 VL，帧组装器忙时保持 FIFO 不弹。
            if (enable && !scan_inhibit && (fifo_count != 5'd0) &&
                allow_start && !grant) begin
                grant    <= 1'b1;
                grant_vl <= ready_fifo[fifo_rd];
                fifo_rd  <= fifo_rd + 4'd1;
                pop_now   = 1;
            end

            // 4 VL/拍扫描；listed 防止 FIFO 重复入队，start_ack 后清除。
            enq_count = 0;
            if (enable && !enable_q) begin
                fifo_wr    <= 4'd0;
                fifo_rd    <= 4'd0;
                fifo_count <= 5'd0;
                listed     <= {N_VL{1'b0}};
                armed      <= {N_VL{1'b0}};
            end else if (!enable) begin
                fifo_count <= 5'd0;
                listed     <= {N_VL{1'b0}};
            end else if (!scan_inhibit && scan_valid_q && !start_ack) begin
                for (j = 0; j < 4; j = j + 1) begin
                    id_w = scan_idx_q * 4 + j;
                    case (j)
                        0: q_sel = q_t0;
                        1: q_sel = q_t1;
                        2: q_sel = q_t2;
                        default: q_sel = q_t3;
                    endcase
                    ready_w = !armed[id_w] || (q_sel < now_plus1);
                    if ((id_w < N_VL) && scan_en[j] && ready_w && !listed[id_w] &&
                        (enq_count < (16 - fifo_count + pop_now))) begin
                        wr_slot = fifo_wr + enq_count[3:0];
                        ready_fifo[wr_slot] <= id_w;
                        listed[id_w] <= 1'b1;
                        enq_count = enq_count + 1;
                    end
                end
                fifo_wr    <= fifo_wr + enq_count[3:0];
                fifo_count <= fifo_count - pop_now + enq_count[4:0];
            end else begin
                fifo_count <= fifo_count - pop_now;
            end

            enable_q <= enable;
        end
    end

endmodule
