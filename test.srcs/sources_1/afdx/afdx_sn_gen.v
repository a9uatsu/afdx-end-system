// =============================================================================
// 文件名  : afdx_sn_gen.v
// 模块    : afdx_sn_gen
// 功能    : 发送侧序列号管理（每个发送 VL 独立计数）
//           规则：1..255 循环，0 保留为复位/重新开始语义
//           内部保存"下一个待发送的 SN"，初值 1
// =============================================================================
`include "afdx_defs.vh"

module afdx_sn_gen #(
    parameter N_VL = 4,
    parameter VW   = 2          // 索引位宽 = $clog2(N_VL)
) (
    input  wire             clk,
    input  wire             reset,
    input  wire             init,       // 脉冲：全部 VL 的 SN 复位为 1
    input  wire             inc_en,     // 脉冲：该 VL 一帧发送完成
    input  wire [VW-1:0]    inc_vl,
    input  wire [VW-1:0]    rd_vl,
    output wire [7:0]       rd_sn       // 本次发送该 VL 应使用的 SN
);

    reg [7:0] sn [0:N_VL-1];
    integer   i;

    assign rd_sn = sn[rd_vl];

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < N_VL; i = i + 1)
                sn[i] <= 8'd1;
        end else if (init) begin
            for (i = 0; i < N_VL; i = i + 1)
                sn[i] <= 8'd1;
        end else if (inc_en) begin
            sn[inc_vl] <= (sn[inc_vl] == `SN_MAX) ? `SN_MIN : (sn[inc_vl] + 8'd1);
        end
    end

endmodule
