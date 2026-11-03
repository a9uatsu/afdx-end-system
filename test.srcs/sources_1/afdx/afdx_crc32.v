// =============================================================================
// 文件名  : afdx_crc32.v
// 模块    : afdx_crc32
// 功能    : 以太网帧校验序列 FCS 的 CRC-32 计算（比特序反射，多项式 0xEDB88320）
//           与标准 CRC-32（等价于 Python binascii.crc32）一致：
//             初值 0xFFFFFFFF，逐字节反射处理，最终结果取反。
// 用法    : init 脉冲装初值；en 有效时吞入 1 字节 din。
//           fcs 为最终 FCS 值，线上按小端字节序发送：
//             fcs[7:0] -> fcs[15:8] -> fcs[23:16] -> fcs[31:24]
// =============================================================================
`include "afdx_defs.vh"

module afdx_crc32 (
    input  wire        clk,
    input  wire        reset,   // 同步复位（高有效）
    input  wire        init,    // 脉冲：装初值 0xFFFFFFFF
    input  wire        en,      // 字节有效
    input  wire [7:0]  din,     // 输入字节
    output wire [31:0] crc,     // 当前 CRC 寄存器值
    output wire [31:0] fcs      // 最终 FCS = ~crc
);

    reg [31:0] crc_q;

    // ---------- 单字节 CRC 组合更新（反射算法，8 次移位展开） ----------
    function [31:0] crc_byte;
        input [31:0] c_in;
        input [7:0]  d;
        integer      i;
        reg   [31:0] c;
        begin
            c = c_in ^ {24'h000000, d};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0])
                    c = (c >> 1) ^ 32'hEDB88320;
                else
                    c = (c >> 1);
            end
            crc_byte = c;
        end
    endfunction

    always @(posedge clk) begin
        if (reset || init)
            crc_q <= 32'hFFFFFFFF;
        else if (en)
            crc_q <= crc_byte(crc_q, din);
    end

    assign crc = crc_q;
    assign fcs = ~crc_q;

endmodule
