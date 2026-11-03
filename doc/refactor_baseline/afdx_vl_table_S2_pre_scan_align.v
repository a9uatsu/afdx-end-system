// =============================================================================
// 文件名  : afdx_vl_table.v
// 模块    : afdx_vl_table
// 功能    : 发送 VL 配置表（4 bank RAM，128 VL 目标）
//
// 存储组织：VL 按低 2 位交错到 4 个 bank。
//   bank0: VL 0,4,8...   bank1: VL 1,5,9...
//   bank2: VL 2,6,10...  bank3: VL 3,7,11...
// 每条记录 252 bit：
//   [207:0] ident(MAC/IP/端口/VLID)
//   [239:208] BAG(32 bit)
//   [250:240] 功能数据长度(11 bit)
//   [251] 使能
//
// 读口：
//   1) 扫描口每拍返回 4 个 bank 的使能位；
//   2) 授权后单路同步读出完整记录，供帧组装器锁存。
// =============================================================================
`include "afdx_defs.vh"

module afdx_vl_table #(
    parameter N_VL = 128,
    parameter VW   = 7,
    parameter SW   = 5
) (
    input  wire              clk,
    input  wire              reset,
    // ---- 配置写口 ----
    input  wire              cfg_wr,
    input  wire [VW-1:0]     cfg_vl,
    input  wire [2:0]        cfg_field,
    input  wire [207:0]      cfg_data,
    // ---- 后台扫描口 ----
    input  wire [SW-1:0]     scan_addr,
    output reg  [3:0]        scan_en,
    // ---- 授权后单路同步读 ----
    input  wire              dispatch_req,
    input  wire [VW-1:0]     dispatch_vl,
    output reg               dispatch_valid,
    output wire [251:0]      dispatch_record
);

    localparam BANK_N = (N_VL + 3) / 4;

    (* ramstyle = "M4K", no_rw_check *) reg [251:0] rec_b0 [0:BANK_N-1];
    (* ramstyle = "M4K", no_rw_check *) reg [251:0] rec_b1 [0:BANK_N-1];
    (* ramstyle = "M4K", no_rw_check *) reg [251:0] rec_b2 [0:BANK_N-1];
    (* ramstyle = "M4K", no_rw_check *) reg [251:0] rec_b3 [0:BANK_N-1];

    reg [251:0] q_b0, q_b1, q_b2, q_b3;
    reg [1:0]   dispatch_bank_q;

    wire [VW-1:0] cfg_bank_addr = cfg_vl >> 2;
    wire [1:0]    cfg_bank      = cfg_vl[1:0];
    wire [VW-1:0] disp_bank_addr = dispatch_vl >> 2;
    wire [1:0]    disp_bank      = dispatch_vl[1:0];

    // 扫描地址在 N_VL=4 时只有 bank 地址 0；更小配置也安全回绕到 0。
    wire [SW-1:0] scan_addr_use = (scan_addr < BANK_N) ? scan_addr : {SW{1'b0}};
    wire [SW-1:0] read_bank_addr = dispatch_req ? disp_bank_addr : scan_addr_use;

    always @(posedge clk) begin
        if (cfg_wr) begin
            case (cfg_bank)
                2'd0: case (cfg_field)
                    3'd0: rec_b0[cfg_bank_addr][207:0]   <= cfg_data;
                    3'd1: rec_b0[cfg_bank_addr][239:208] <= cfg_data[31:0];
                    3'd2: rec_b0[cfg_bank_addr][250:240] <= cfg_data[10:0];
                    3'd3: rec_b0[cfg_bank_addr][251]     <= cfg_data[0];
                    default: ;
                endcase
                2'd1: case (cfg_field)
                    3'd0: rec_b1[cfg_bank_addr][207:0]   <= cfg_data;
                    3'd1: rec_b1[cfg_bank_addr][239:208] <= cfg_data[31:0];
                    3'd2: rec_b1[cfg_bank_addr][250:240] <= cfg_data[10:0];
                    3'd3: rec_b1[cfg_bank_addr][251]     <= cfg_data[0];
                    default: ;
                endcase
                2'd2: case (cfg_field)
                    3'd0: rec_b2[cfg_bank_addr][207:0]   <= cfg_data;
                    3'd1: rec_b2[cfg_bank_addr][239:208] <= cfg_data[31:0];
                    3'd2: rec_b2[cfg_bank_addr][250:240] <= cfg_data[10:0];
                    3'd3: rec_b2[cfg_bank_addr][251]     <= cfg_data[0];
                    default: ;
                endcase
                default: case (cfg_field)
                    3'd0: rec_b3[cfg_bank_addr][207:0]   <= cfg_data;
                    3'd1: rec_b3[cfg_bank_addr][239:208] <= cfg_data[31:0];
                    3'd2: rec_b3[cfg_bank_addr][250:240] <= cfg_data[10:0];
                    3'd3: rec_b3[cfg_bank_addr][251]     <= cfg_data[0];
                    default: ;
                endcase
            endcase
        end

        q_b0 <= rec_b0[read_bank_addr];
        q_b1 <= rec_b1[read_bank_addr];
        q_b2 <= rec_b2[read_bank_addr];
        q_b3 <= rec_b3[read_bank_addr];
        dispatch_bank_q  <= disp_bank;
        dispatch_valid   <= dispatch_req;
        scan_en          <= {q_b3[251], q_b2[251], q_b1[251], q_b0[251]};
    end

    assign dispatch_record =
        (dispatch_bank_q == 2'd0) ? q_b0 :
        (dispatch_bank_q == 2'd1) ? q_b1 :
        (dispatch_bank_q == 2'd2) ? q_b2 : q_b3;

endmodule
