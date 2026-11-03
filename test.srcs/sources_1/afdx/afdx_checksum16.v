// =============================================================================
// 文件名  : afdx_checksum16.v
// 模块    : afdx_checksum16
// 功能    : 16 位反码求和校验和（IPv4 头校验和 / UDP 校验和）
//           - 网络字节序（大端）两两成对：word = {第1字节, 第2字节}
//           - 字节数为奇数时按 RFC 768 在末尾补一个 0x00 字节
//           - 最终折叠（进位回卷）后取反
//           - udp_zero_to_ones=1 时结果为 0 则输出 0xFFFF（UDP 规则）
// 用法    : init 脉冲清零 -> en 逐字节喂入 -> finalize 脉冲锁存结果
// =============================================================================
`include "afdx_defs.vh"

module afdx_checksum16 (
    input  wire        clk,
    input  wire        reset,
    input  wire        init,              // 脉冲：清零累加器
    input  wire        en,                // 字节有效
    input  wire [7:0]  din,
    input  wire        finalize,          // 脉冲：锁存校验和
    input  wire        udp_zero_to_ones,  // 1: 结果为0时输出0xFFFF
    output reg  [15:0] checksum,          // 锁存后的校验和
    output reg         valid              // 校验和有效
);

    reg [31:0] acc_q;    // 32 位累加器（最长帧约 759 个字，不会溢出）
    reg [7:0]  hi_q;     // 暂存高字节
    reg        odd_q;    // 1: 存在未配对的字节

    // 若存在未配对字节，按 RFC 768 在末尾补 0x00（作为低字节）
    wire [31:0] acc_final = odd_q ? (acc_q + {16'h0000, hi_q, 8'h00}) : acc_q;
    wire [16:0] s1 = acc_final[15:0] + acc_final[31:16];  // 折叠一次
    wire [15:0] s2 = s1[15:0] + s1[16];                   // 进位回卷

    always @(posedge clk) begin
        if (reset) begin
            acc_q    <= 32'h0;
            hi_q     <= 8'h00;
            odd_q    <= 1'b0;
            checksum <= 16'h0000;
            valid    <= 1'b0;
        end else if (init) begin
            acc_q    <= 32'h0;
            hi_q     <= 8'h00;
            odd_q    <= 1'b0;
            valid    <= 1'b0;
        end else if (en) begin
            if (!odd_q) begin
                hi_q  <= din;
                odd_q <= 1'b1;
            end else begin
                acc_q <= acc_q + {16'h0000, hi_q, din};
                odd_q <= 1'b0;
            end
        end else if (finalize) begin
            checksum <= (~s2 == 16'h0000 && udp_zero_to_ones) ? 16'hFFFF : ~s2;
            valid    <= 1'b1;
        end
    end

endmodule
