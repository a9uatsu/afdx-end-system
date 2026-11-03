// =============================================================================
// 文件名  : afdx_scheduler.v
// 模块    : afdx_scheduler
// 功能    : 发送调度（BAG 流量整形 + 轮询仲裁）
//
// BAG 语义（ARINC 664 Part 7）：
//   BAG 是同一虚拟链路相邻两帧"开始发送"之间的最小时间间隔。
//   因此计时器在"帧真正开始发送"的时刻（start_ack）按 BAG 重装，
//   而不是在授权时刻重装 —— 否则授权到实际开始之间的准备延迟会造成
//   下一帧过早开始，实测起始间隔可能小于 BAG。
//
// 时序：
//   1) 计时器倒计时到 0 且不在"已授权待发送"状态 -> 该 VL 就绪
//   2) 轮询仲裁选出一个就绪 VL -> grant（置 in-flight）
//   3) 帧开始发送 -> start_ack：重装计时器、清除 in-flight
//   4) 计时器再次到 0 -> 下一帧最早开始时刻 >= 上一帧开始时刻 + BAG
// =============================================================================
`include "afdx_defs.vh"

module afdx_scheduler #(
    parameter N_VL = 4,
    parameter VW   = 2,
    parameter CW   = 32         // BAG 计数器位宽
) (
    input  wire               clk,
    input  wire               reset,
    input  wire               enable,        // 配置完成后置 1 开始调度
    input  wire [N_VL-1:0]    vl_en,         // 各 VL 使能
    input  wire [N_VL*CW-1:0] bag_vec,       // 各 VL 的 BAG（时钟周期数）
    input  wire               start_ack,     // 脉冲：一帧真正开始发送
    input  wire [VW-1:0]      start_vl,      // 该帧的 VL
    input  wire               allow_start,   // 帧组装器空闲，可立即接受授权
    output reg                grant,         // 脉冲：授权发送一帧
    output reg  [VW-1:0]      grant_vl       // 被授权的 VL
);

    reg [CW-1:0]      tim      [0:N_VL-1];   // BAG 倒计时器
    reg [N_VL-1:0]    inflight;              // 已授权、尚未开始发送
    reg [VW-1:0]      rr;                    // 轮询指针
    reg               enable_q;
    reg [7:0]         wd_cnt;                // 授权看门狗（防止授权丢失导致 VL 永久阻塞）

    integer           i;
    integer           sum;
    reg [VW-1:0]      scan;
    reg               sel_found;
    reg [VW-1:0]      sel;

    // ---------------- 组合仲裁：从轮询指针开始找第一个就绪 VL ----------------
    always @(*) begin
        sel_found = 1'b0;
        sel       = {VW{1'b0}};
        for (i = 0; i < N_VL; i = i + 1) begin
            sum = rr + i;
            if (sum >= N_VL) sum = sum - N_VL;
            scan = sum[VW-1:0];
            if (!sel_found && vl_en[scan] && !inflight[scan] &&
                (tim[scan] == {CW{1'b0}})) begin
                sel_found = 1'b1;
                sel       = scan;
            end
        end
    end

    // ---------------- 计时器、授权与重装 ----------------
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < N_VL; i = i + 1)
                tim[i] <= {CW{1'b0}};
            inflight <= {N_VL{1'b0}};
            rr       <= {VW{1'b0}};
            grant    <= 1'b0;
            grant_vl <= {VW{1'b0}};
            enable_q <= 1'b0;
            wd_cnt   <= 8'd0;
        end else begin
            grant <= 1'b0;

            // 首次使能：清空计时器与在途标志（会产生一个启动突发，属正常行为）
            if (enable && !enable_q) begin
                for (i = 0; i < N_VL; i = i + 1)
                    tim[i] <= {CW{1'b0}};
                inflight <= {N_VL{1'b0}};
            end

            // BAG 倒计时
            for (i = 0; i < N_VL; i = i + 1) begin
                if (tim[i] != {CW{1'b0}})
                    tim[i] <= tim[i] - 1'b1;
            end

            // 帧真正开始发送：按 BAG 重装计时器，并清除在途标志
            if (start_ack) begin
                tim[start_vl]      <= bag_vec[start_vl*CW +: CW];
                inflight[start_vl] <= 1'b0;
            end

            // 授权：仅在帧组装器空闲、且上一拍没有刚发出授权时发出。
            // 注意 grant 是寄存器输出，本拍看到的 grant 也意味着"刚授权过"，
            // 必须抑制，否则两拍内会连续授权、把前一次授权丢掉。
            if (enable && sel_found && allow_start && !grant) begin
                grant            <= 1'b1;
                grant_vl         <= sel;
                inflight[sel]    <= 1'b1;
                rr               <= (sel == N_VL-1) ? {VW{1'b0}} : (sel + 1'b1);
            end

            // 看门狗：在途状态超过 255 个时钟仍未开始发送则强制清除
            if (start_ack)
                wd_cnt <= 8'd0;
            else if (|inflight)
                wd_cnt <= wd_cnt + 8'd1;
            else
                wd_cnt <= 8'd0;

            if (wd_cnt == 8'hFF)
                inflight <= {N_VL{1'b0}};

            enable_q <= enable;
        end
    end

endmodule
