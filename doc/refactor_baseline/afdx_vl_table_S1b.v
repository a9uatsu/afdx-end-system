// =============================================================================
// 文件名  : afdx_vl_table.v
// 模块    : afdx_vl_table
// 功能    : 发送 VL 配置表（可在线配置，寄存器实现）
//           每个 VL 记录：目的/源 MAC、目的/源 IP、目的/源 UDP 端口、VLID、
//                         BAG（时钟周期数）、功能数据长度、使能
// 配置接口: cfg_wr 脉冲 + cfg_vl 索引 + cfg_field 字段选择 + cfg_data
//             field 0 = ident（208 位：vlid/端口/IP/MAC）
//             field 1 = BAG（时钟周期数）
//             field 2 = 功能数据长度
//             field 3 = 使能
// =============================================================================
`include "afdx_defs.vh"

module afdx_vl_table #(
    parameter N_VL = 4,
    parameter VW   = 2
) (
    input  wire             clk,
    input  wire             reset,
    // ---- 配置写口 ----
    input  wire             cfg_wr,
    input  wire [VW-1:0]    cfg_vl,
    input  wire [2:0]       cfg_field,
    input  wire [207:0]     cfg_data,
    // ---- 读取（组合读，按索引） ----
    input  wire [VW-1:0]    rd_vl,
    output wire [47:0]      rd_dst_mac,
    output wire [47:0]      rd_src_mac,
    output wire [31:0]      rd_dst_ip,
    output wire [31:0]      rd_src_ip,
    output wire [15:0]      rd_dst_port,
    output wire [15:0]      rd_src_port,
    output wire [15:0]      rd_vlid,
    output wire [31:0]      rd_bag,
    output wire [10:0]      rd_len,
    output wire             rd_en,
    output wire [N_VL-1:0]  en_vec,     // 全部 VL 的使能（供调度器扫描）
    output wire [N_VL*32-1:0] bag_vec   // 全部 VL 的 BAG（供调度器使用）
);

    // ident 记录：[207:160] dst_mac, [159:112] src_mac, [111:80] dst_ip,
    //              [79:48] src_ip, [47:32] dst_port, [31:16] src_port, [15:0] vlid
    reg [207:0]  ident  [0:N_VL-1];
    reg [31:0]   bag    [0:N_VL-1];
    reg [10:0]   dlen   [0:N_VL-1];
    reg [N_VL-1:0] en_r;

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < N_VL; i = i + 1) begin
                ident[i] <= 208'h0;
                bag[i]   <= 32'd0;
                dlen[i]  <= 11'd0;
            end
            en_r <= {N_VL{1'b0}};
        end else if (cfg_wr) begin
            case (cfg_field)
                3'd0: ident[cfg_vl] <= cfg_data[207:0];
                3'd1: bag[cfg_vl]   <= cfg_data[31:0];
                3'd2: dlen[cfg_vl]  <= cfg_data[10:0];
                3'd3: en_r[cfg_vl]  <= cfg_data[0];
                default: ;
            endcase
        end
    end

    assign rd_dst_mac  = ident[rd_vl][207:160];
    assign rd_src_mac  = ident[rd_vl][159:112];
    assign rd_dst_ip   = ident[rd_vl][111:80];
    assign rd_src_ip   = ident[rd_vl][79:48];
    assign rd_dst_port = ident[rd_vl][47:32];
    assign rd_src_port = ident[rd_vl][31:16];
    assign rd_vlid     = ident[rd_vl][15:0];
    assign rd_bag      = bag[rd_vl];
    assign rd_len      = dlen[rd_vl];
    assign rd_en       = en_r[rd_vl];
    assign en_vec      = en_r;

    genvar gv;
    generate
        for (gv = 0; gv < N_VL; gv = gv + 1) begin : g_bag
            assign bag_vec[gv*32 +: 32] = bag[gv];
        end
    endgenerate

endmodule
