// =============================================================================
// 文件名  : afdx_snmp_agent_core.v
// 模块    : afdx_snmp_agent_core
// 功能    : SNMP v2c Agent 核心：多 varbind / GetBulk / Get / GetNext / Set
//
// 容量边界：
//   请求最多 4 个 varbind，请求报文最长 128 字节；
//   GetBulk max-repetitions <= 4，单响应最多 6 个 varbind；
//   响应 RAM 512 字节，BER 长度支持单字节和 0x81 长格式。
// 外部 afdx_snmp_agent 保持原端口接口不变。
// =============================================================================
`include "afdx_defs.vh"

module afdx_snmp_agent_core #(
    parameter [47:0] COMMUNITY  = 48'h7075626c6963,  // "public"
    parameter [7:0]  SYS_NAME_LEN  = 8'd7,
    parameter [7:0]  SYS_DESCR_LEN = 8'd16
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] sys_uptime,
    input  wire [31:0] cnt_tx_frames,
    input  wire [31:0] cnt_rx_frames,
    input  wire [31:0] cnt_rx_errors,
    input  wire [31:0] cnt_dup,
    input  wire [31:0] cnt_ic_err,
    input  wire [7:0]  vl_fault,
    input  wire [15:0] vl_capacity,
    input  wire        req_wr,
    input  wire [7:0]  req_data,
    input  wire        req_last,
    input  wire        req_start,
    output reg         resp_valid,
    output reg  [7:0]  resp_data,
    output reg         resp_last,
    output reg         resp_begin,
    output reg  [15:0] req_cnt,
    output reg  [15:0] resp_cnt,
    output reg  [15:0] drop_cnt,
    output reg  [15:0] no_such_cnt,
    output reg         trap_valid,
    output reg  [7:0]  trap_data,
    output reg         trap_last,
    output reg         trap_begin,
    output reg  [15:0] trap_cnt
);

    localparam [3:0] MIB_N      = 4'd10;
    localparam [3:0] KIND_UNK   = 4'd10;
    localparam [3:0] KIND_END   = 4'd11;
    localparam [3:0] KIND_NULL  = 4'd12;
    localparam [2:0] MAX_REQ    = 3'd4;
    localparam [2:0] MAX_RESP   = 3'd6;
    localparam [2:0] MAX_REP    = 3'd4;

    // =========================================================================
    // 请求 RAM 与解析视图
    // =========================================================================
    (* ramstyle = "M4K", no_rw_check *) reg [7:0] rxb [0:255];
    reg [7:0]  rxb_q;
    reg [7:0]  rxb_raddr;
    reg [7:0]  rh [0:127];
    reg [8:0]  wrp;
    reg [7:0]  scan_i, scan_end;
    reg [8:0]  req_len_r;
    reg        scanning, parse_ready, req_overflow;
    reg [15:0] wr_count;

    always @(*) begin
        rxb_raddr = scanning ? (scan_i + 8'd1) : 8'd0;
    end

    always @(posedge clk) begin
        if (reset) begin
            wrp        <= 9'd0;
            wr_count   <= 16'd0;
            req_overflow <= 1'b0;
        end else if (req_start) begin
            wrp        <= 9'd0;
            wr_count   <= 16'd0;
            req_overflow <= 1'b0;
        end else if (req_wr) begin
            if (wrp < 9'd256)
                rxb[wrp[7:0]] <= req_data;
            else
                req_overflow <= 1'b1;
            wrp      <= wrp + 9'd1;
            wr_count <= wr_count + 16'd1;
        end
        rxb_q <= rxb[rxb_raddr];
    end

    // =========================================================================
    // BER 结构与请求 varbind 定位（请求仅使用短格式长度）
    // =========================================================================
    wire [7:0] p_comm = 8'd5;
    wire [7:0] comm_len = rh[p_comm + 8'd1];
    wire [7:0] p_pdu = p_comm + 8'd2 + comm_len;
    wire [7:0] p_rid = p_pdu + 8'd2;
    wire [7:0] rid_len = rh[p_rid + 8'd1];
    wire [7:0] p_est = p_rid + 8'd2 + rid_len;
    wire [7:0] p_eid = p_est + 8'd3;
    wire [7:0] p_vbl = p_eid + 8'd3;
    wire [7:0] p_vb = p_vbl + 8'd2;
    wire [7:0] vbl_len = rh[p_vbl + 8'd1];
    wire [8:0] vbl_end = p_vbl + 8'd2 + vbl_len;
    wire [7:0] ver_num = rh[4];

    wire is_getbulk = (rh[p_pdu] == 8'hA5);
    wire is_getnext = (rh[p_pdu] == 8'hA1);
    wire is_set     = (rh[p_pdu] == 8'hA3);
    wire is_get     = (rh[p_pdu] == 8'hA0);

    reg [7:0] vb_pos [0:4];
    reg [7:0] oid_pos_v [0:3];
    reg [7:0] oid_len_v [0:3];
    reg [7:0] vb_end_v [0:3];
    reg       vb_present [0:3];
    reg       oid_fit [0:3];
    reg       val_fit [0:3];
    integer   pj;
    always @(*) begin
        vb_pos[0] = p_vb;
        for (pj = 0; pj < 4; pj = pj + 1) begin
            oid_pos_v[pj] = vb_pos[pj] + 8'd2;
            oid_len_v[pj] = rh[oid_pos_v[pj] + 8'd1];
            vb_end_v[pj] = vb_pos[pj] + 8'd2 + rh[vb_pos[pj] + 8'd1];
            vb_pos[pj + 1] = vb_end_v[pj];
            vb_present[pj] = (vb_pos[pj] >= p_vb) && (vb_pos[pj] < vbl_end) &&
                             (vb_pos[pj] < req_len_r[7:0]) &&
                             (rh[vb_pos[pj]] == 8'h30) &&
                             (rh[vb_pos[pj] + 8'd1] < 8'd128);
            oid_fit[pj] = (oid_pos_v[pj] >= p_vb) &&
                          (oid_pos_v[pj] + 8'd2 + oid_len_v[pj] <= vb_end_v[pj]) &&
                          (rh[oid_pos_v[pj]] == 8'h06) &&
                          (oid_len_v[pj] > 8'd1) && (oid_len_v[pj] < 8'd17);
            if (is_set)
                val_fit[pj] = (oid_pos_v[pj] + 8'd2 + oid_len_v[pj] < vb_end_v[pj]) &&
                              (rh[oid_pos_v[pj] + 8'd2 + oid_len_v[pj]] < 8'd128) &&
                              (oid_pos_v[pj] + 8'd4 + oid_len_v[pj] +
                               rh[oid_pos_v[pj] + 8'd3 + oid_len_v[pj]] == vb_end_v[pj]);
            else
                val_fit[pj] = (oid_pos_v[pj] + 8'd4 + oid_len_v[pj] == vb_end_v[pj]) &&
                              (rh[oid_pos_v[pj] + 8'd2 + oid_len_v[pj]] == 8'h05) &&
                              (rh[oid_pos_v[pj] + 8'd3 + oid_len_v[pj]] == 8'd0);
        end
    end

    reg [2:0] req_count;
    integer   pc;
    always @(*) begin
        req_count = 3'd0;
        for (pc = 0; pc < 4; pc = pc + 1)
            if (vb_present[pc]) req_count = req_count + 3'd1;
    end

    reg chain_ok;
    always @(*) begin
        chain_ok = (req_count != 3'd0);
        for (pj = 0; pj < 4; pj = pj + 1) begin
            if (pj < req_count)
                chain_ok = chain_ok && vb_present[pj] && oid_fit[pj] && val_fit[pj];
        end
        if (req_count < 4)
            chain_ok = chain_ok && (vb_pos[req_count] == vbl_end);
        else
            chain_ok = chain_ok && (vb_pos[4] == vbl_end);
    end

    wire [7:0] nonrep_in = rh[p_est + 8'd2];
    wire [7:0] maxrep_in = rh[p_eid + 8'd2];

    wire ok_ver  = (rh[0] == 8'h30) && (rh[2] == 8'h02) &&
                   (rh[3] == 8'h01) && (req_len_r < 9'd129) &&
                   (req_len_r > 9'd16) && ({1'b0, rh[1]} + 9'd2 == req_len_r);
    wire ok_comm = (rh[p_comm] == 8'h04) && (comm_len == 8'd6) &&
                   ({rh[p_comm+8'd2], rh[p_comm+8'd3], rh[p_comm+8'd4],
                     rh[p_comm+8'd5], rh[p_comm+8'd6], rh[p_comm+8'd7]} == COMMUNITY);
    wire ok_pdu  = is_get || is_getnext || is_set || is_getbulk;
    wire ok_rid  = (rh[p_rid] == 8'h02) && (rid_len > 8'd0) && (rid_len < 8'd6);
    wire ok_fields = (rh[p_est] == 8'h02) && (rh[p_est+8'd1] == 8'd1) &&
                     (rh[p_eid] == 8'h02) && (rh[p_eid+8'd1] == 8'd1) &&
                     (!is_getbulk ? ((nonrep_in == 8'd0) && (maxrep_in == 8'd0)) : 1'b1) &&
                     (!is_getbulk ? 1'b1 : ((nonrep_in <= MAX_REQ) && (maxrep_in <= MAX_REP)));
    wire ok_vbl  = (rh[p_vbl] == 8'h30) &&
                   (p_vbl + 8'd2 + vbl_len == req_len_r[7:0]);
    wire ok_pdu_len = (rh[p_pdu+8'd1] < 8'd128) &&
                      (p_pdu + 8'd2 + rh[p_pdu+8'd1] == req_len_r[7:0]);
    wire msg_ok = ok_ver && ok_comm && ok_pdu && ok_rid && ok_fields &&
                  ok_vbl && ok_pdu_len && chain_ok && !req_overflow;

    // =========================================================================
    // MIB 对象描述
    // =========================================================================
    function [3:0] mib_family;
        input [3:0] e;
        begin mib_family = (e < 4'd3) ? 4'd0 : 4'd1; end
    endfunction

    function [7:0] mib_sub;
        input [3:0] e;
        begin
            case (e)
                4'd0: mib_sub = 8'd1;
                4'd1: mib_sub = 8'd3;
                4'd2: mib_sub = 8'd5;
                default: mib_sub = {4'h0, e} - 8'd2;
            endcase
        end
    endfunction

    function [8:0] mib_oid_len;
        input [3:0] e;
        begin mib_oid_len = (e < 4'd3) ? 9'd8 : 9'd10; end
    endfunction

    function [7:0] mib_oid_byte;
        input [3:0] e;
        input [3:0] k;
        reg [7:0] sub;
        begin
            sub = mib_sub(e);
            case (k)
                4'd0: mib_oid_byte = 8'h2B;
                4'd1: mib_oid_byte = 8'h06;
                4'd2: mib_oid_byte = 8'h01;
                4'd3: mib_oid_byte = mib_family(e) ? 8'h04 : 8'h02;
                4'd4: mib_oid_byte = 8'h01;
                4'd5: mib_oid_byte = mib_family(e) ? 8'h86 : 8'h01;
                4'd6: mib_oid_byte = mib_family(e) ? 8'h8D : sub;
                4'd7: mib_oid_byte = mib_family(e) ? 8'h1F : 8'h00;
                4'd8: mib_oid_byte = sub;
                default: mib_oid_byte = 8'h00;
            endcase
        end
    endfunction

    function [7:0] mib_value_byte;
        input [3:0] e;
        input [3:0] idx;
        reg [31:0] n;
        begin
            n = 32'd0;
            case (e)
                4'd1: n = sys_uptime;
                4'd3: n = cnt_tx_frames;
                4'd4: n = cnt_rx_frames;
                4'd5: n = cnt_rx_errors;
                4'd6: n = cnt_dup;
                4'd7: n = cnt_ic_err;
                4'd8: n = {24'h0, vl_fault};
                4'd9: n = {16'h0, vl_capacity};
                default: n = 32'd0;
            endcase
            if (e == 4'd0) begin
                case (idx)
                    4'd0: mib_value_byte = 8'h41; 4'd1: mib_value_byte = 8'h46;
                    4'd2: mib_value_byte = 8'h44; 4'd3: mib_value_byte = 8'h58;
                    4'd4: mib_value_byte = 8'h2D; 4'd5: mib_value_byte = 8'h45;
                    4'd6: mib_value_byte = 8'h53; 4'd7: mib_value_byte = 8'h20;
                    4'd8: mib_value_byte = 8'h45; 4'd9: mib_value_byte = 8'h51;
                    4'd10: mib_value_byte = 8'h36; 4'd11: mib_value_byte = 8'h48;
                    4'd12: mib_value_byte = 8'h4C; 4'd13: mib_value_byte = 8'h31;
                    4'd14: mib_value_byte = 8'h33; default: mib_value_byte = 8'h30;
                endcase
            end else if (e == 4'd2) begin
                case (idx)
                    4'd0: mib_value_byte = 8'h61; 4'd1: mib_value_byte = 8'h66;
                    4'd2: mib_value_byte = 8'h64; 4'd3: mib_value_byte = 8'h78;
                    4'd4: mib_value_byte = 8'h2D; 4'd5: mib_value_byte = 8'h65;
                    default: mib_value_byte = 8'h73;
                endcase
            end else begin
                case (idx)
                    4'd0: mib_value_byte = n[31:24];
                    4'd1: mib_value_byte = n[23:16];
                    4'd2: mib_value_byte = n[15:8];
                    default: mib_value_byte = n[7:0];
                endcase
            end
        end
    endfunction

    // =========================================================================
    // 请求 varbind 的命中/后继查找
    // =========================================================================
    reg [7:0] req_oid [0:3][0:15];
    reg [3:0] req_oid_len [0:3];
    reg       req_hit [0:3];
    reg [3:0] req_hit_idx [0:3];
    reg       req_next_found [0:3];
    reg [3:0] req_next_idx [0:3];
    integer   hj, hm, hn;
    reg       h_match, h_gt, h_dec;
    always @(*) begin
        for (hj = 0; hj < 4; hj = hj + 1) begin
            req_hit[hj] = 1'b0;
            req_hit_idx[hj] = 4'd0;
            req_next_found[hj] = 1'b0;
            req_next_idx[hj] = 4'd0;
            for (hm = MIB_N - 1; hm >= 0; hm = hm - 1) begin
                h_match = (mib_oid_len(hm[3:0]) == {1'b0, req_oid_len[hj]});
                for (hn = 0; hn < 16; hn = hn + 1) begin
                    if (hn < req_oid_len[hj])
                        h_match = h_match &&
                            (req_oid[hj][hn] == mib_oid_byte(hm[3:0], hn[3:0]));
                end
                if (h_match) begin
                    req_hit[hj] = 1'b1;
                    req_hit_idx[hj] = hm[3:0];
                end
                h_gt = 1'b0;
                h_dec = 1'b0;
                for (hn = 0; hn < 16; hn = hn + 1) begin
                    if (!h_dec && (hn < req_oid_len[hj]) &&
                        (hn < mib_oid_len(hm[3:0]))) begin
                        if (req_oid[hj][hn] < mib_oid_byte(hm[3:0], hn[3:0])) begin
                            h_gt = 1'b1; h_dec = 1'b1;
                        end else if (req_oid[hj][hn] > mib_oid_byte(hm[3:0], hn[3:0])) begin
                            h_gt = 1'b0; h_dec = 1'b1;
                        end
                    end
                end
                if (!h_dec)
                    h_gt = (mib_oid_len(hm[3:0]) > {1'b0, req_oid_len[hj]});
                if (h_gt) begin
                    req_next_found[hj] = 1'b1;
                    req_next_idx[hj] = hm[3:0];
                end
            end
        end
    end

    // =========================================================================
    // 输出 varbind 计划
    // =========================================================================
    reg [3:0] out_kind [0:5];
    reg [1:0] out_src [0:5];
    reg [3:0] out_end_idx [0:5];
    reg [2:0] out_count;
    reg [2:0] out_nosuch_count;
    reg [2:0] bulk_nonrep;
    reg [5:0] bulk_planned;
    reg       too_big;
    integer   oj, orp, oc;
    always @(*) begin
        for (oj = 0; oj < 6; oj = oj + 1) begin
            out_kind[oj] = KIND_UNK;
            out_src[oj] = 2'd0;
            out_end_idx[oj] = 4'hF;
        end
        oc = 0;
        bulk_nonrep = (nonrep_in < {5'h0, req_count}) ?
                      nonrep_in[2:0] : req_count;
        bulk_planned = bulk_nonrep +
                       ((req_count - bulk_nonrep) * maxrep_in[2:0]);
        too_big = is_getbulk &&
                  ((bulk_planned > MAX_RESP) || (maxrep_in > MAX_REP) ||
                   (nonrep_in > MAX_REQ));

        if (too_big) begin
            out_count = 3'd0;
        end else if (is_getbulk) begin
            for (pj = 0; pj < 4; pj = pj + 1) begin
                if ((pj < bulk_nonrep) && (pj < req_count) && (oc < MAX_RESP)) begin
                    out_kind[oc] = req_next_found[pj] ? req_next_idx[pj] : KIND_END;
                    out_src[oc] = pj[1:0];
                    if (!req_next_found[pj]) out_end_idx[oc] = 4'hF;
                    oc = oc + 1;
                end
            end
            for (orp = 0; orp < 4; orp = orp + 1) begin
                if (orp < maxrep_in) begin
                    for (pj = 0; pj < 4; pj = pj + 1) begin
                        if ((pj >= bulk_nonrep) && (pj < req_count) && (oc < MAX_RESP)) begin
                            if (!req_next_found[pj]) begin
                                if (orp == 0) begin
                                    out_kind[oc] = KIND_END;
                                    out_src[oc] = pj[1:0];
                                    out_end_idx[oc] = 4'hF;
                                    oc = oc + 1;
                                end
                            end else if ((req_next_idx[pj] + orp[3:0]) < MIB_N) begin
                                out_kind[oc] = req_next_idx[pj] + orp[3:0];
                                out_src[oc] = pj[1:0];
                                oc = oc + 1;
                            end else if ((req_next_idx[pj] + orp[3:0]) == MIB_N) begin
                                out_kind[oc] = KIND_END;
                                out_src[oc] = pj[1:0];
                                out_end_idx[oc] = req_next_idx[pj] + orp[3:0] - 4'd1;
                                oc = oc + 1;
                            end
                        end
                    end
                end
            end
            out_count = oc[2:0];
        end else begin
            for (pj = 0; pj < 4; pj = pj + 1) begin
                if ((pj < req_count) && (oc < MAX_RESP)) begin
                    if (is_set) begin
                        out_kind[oc] = KIND_NULL;
                    end else if (is_getnext) begin
                        out_kind[oc] = req_next_found[pj] ? req_next_idx[pj] : KIND_END;
                        if (!req_next_found[pj]) out_end_idx[oc] = 4'hF;
                    end else begin
                        out_kind[oc] = req_hit[pj] ? req_hit_idx[pj] : KIND_UNK;
                    end
                    out_src[oc] = pj[1:0];
                    oc = oc + 1;
                end
            end
            out_count = oc[2:0];
        end
        out_nosuch_count = 3'd0;
        for (oj = 0; oj < 6; oj = oj + 1)
            if ((oj < out_count) && (out_kind[oj] == KIND_UNK))
                out_nosuch_count = out_nosuch_count + 3'd1;
    end

    // =========================================================================
    // 当前输出 varbind 的 OID/值
    // =========================================================================
    reg [2:0] build_vb;
    reg [3:0] build_k;
    reg [3:0] cur_kind;
    reg [1:0] cur_src;
    reg [7:0] cur_oid_len;
    reg [7:0] cur_val_len;
    reg [7:0] cur_val_tag;
    reg [31:0] cur_val_num;
    reg        cur_val_str;
    always @(*) begin
        cur_kind    = out_kind[build_vb];
        cur_src     = out_src[build_vb];
        cur_oid_len = 8'd0;
        cur_val_len = 8'd0;
        cur_val_tag = 8'h05;
        cur_val_num = 32'd0;
        cur_val_str = 1'b0;
        if (cur_kind < MIB_N) begin
            cur_oid_len = mib_oid_len(cur_kind);
            case (cur_kind)
                4'd0: begin cur_val_tag=8'h04; cur_val_len=SYS_DESCR_LEN; cur_val_str=1'b1; end
                4'd1: begin cur_val_tag=8'h43; cur_val_len=8'd4; cur_val_num=sys_uptime; end
                4'd2: begin cur_val_tag=8'h04; cur_val_len=SYS_NAME_LEN; cur_val_str=1'b1; end
                4'd3: begin cur_val_tag=8'h41; cur_val_len=8'd4; cur_val_num=cnt_tx_frames; end
                4'd4: begin cur_val_tag=8'h41; cur_val_len=8'd4; cur_val_num=cnt_rx_frames; end
                4'd5: begin cur_val_tag=8'h41; cur_val_len=8'd4; cur_val_num=cnt_rx_errors; end
                4'd6: begin cur_val_tag=8'h41; cur_val_len=8'd4; cur_val_num=cnt_dup; end
                4'd7: begin cur_val_tag=8'h41; cur_val_len=8'd4; cur_val_num=cnt_ic_err; end
                4'd8: begin cur_val_tag=8'h02;
                             cur_val_num={24'h0,vl_fault};
                             cur_val_len=vl_fault[7] ? 8'd2 : 8'd1; end
                default: begin cur_val_tag=8'h02; cur_val_len=8'd2;
                               cur_val_num={16'h0,vl_capacity}; end
            endcase
        end else begin
            if ((cur_kind == KIND_END) && (out_end_idx[build_vb] != 4'hF)) begin
                cur_oid_len = mib_oid_len(out_end_idx[build_vb]);
            end else begin
                cur_oid_len = req_oid_len[cur_src];
            end
            case (cur_kind)
                KIND_END:  begin cur_val_tag=8'h82; cur_val_len=8'd0; end
                KIND_NULL: begin cur_val_tag=8'h05; cur_val_len=8'd0; end
                default:   begin cur_val_tag=8'h80; cur_val_len=8'd0; end
            endcase
        end
    end

    reg [7:0] cur_oid_byte;
    always @(*) begin
        if (cur_kind < MIB_N)
            cur_oid_byte = mib_oid_byte(cur_kind, build_k[3:0]);
        else if ((cur_kind == KIND_END) && (out_end_idx[build_vb] != 4'hF))
            cur_oid_byte = mib_oid_byte(out_end_idx[build_vb], build_k[3:0]);
        else
            cur_oid_byte = req_oid[cur_src][build_k[3:0]];
    end

    reg [7:0] cur_val_byte;
    always @(*) begin
        if (cur_val_str)
            cur_val_byte = mib_value_byte(cur_kind, build_k[3:0]);
        else begin
            case (cur_val_len)
                8'd1: cur_val_byte = cur_val_num[7:0];
                8'd2: cur_val_byte = (build_k == 4'd0) ? cur_val_num[15:8]
                                                       : cur_val_num[7:0];
                default: case (build_k[1:0])
                             2'd0: cur_val_byte = cur_val_num[31:24];
                             2'd1: cur_val_byte = cur_val_num[23:16];
                             2'd2: cur_val_byte = cur_val_num[15:8];
                             default: cur_val_byte = cur_val_num[7:0];
                         endcase
            endcase
        end
    end

    // =========================================================================
    // varbind-list 构建
    // =========================================================================
    (* ramstyle = "M4K", no_rw_check *) reg [7:0] vbl_ram [0:511];
    reg [7:0]  vbl_q;
    reg [8:0]  vbl_raddr;
    reg [8:0]  vw;
    reg [9:0]  vlen_r;
    reg [3:0]  bs;
    reg        build_toggle;
    reg        build_toggle_seen, header_toggle;
    localparam [3:0] B_IDLE=0, B_SEQ=1, B_SLEN=2, B_OTAG=3, B_OLEN=4,
                     B_OID=5, B_VTAG=6, B_VLEN=7, B_VAL=8, B_DONE=9;
    wire [7:0] vb_rec_len = 8'd4 + cur_oid_len + cur_val_len;

    always @(posedge clk) begin
        if (reset) begin
            bs <= B_IDLE; vw <= 9'd0; build_vb <= 3'd0; build_k <= 4'd0;
            build_toggle_seen <= 1'b0; header_toggle <= 1'b0;
        end else begin
            case (bs)
            B_IDLE: begin
                if (build_toggle != build_toggle_seen) begin
                    build_toggle_seen <= build_toggle;
                    vw <= 9'd0; build_vb <= 3'd0; build_k <= 4'd0;
                    if (out_count == 0) bs <= B_DONE;
                    else bs <= B_SEQ;
                end
            end
            B_SEQ: begin vbl_ram[vw] <= 8'h30; vw <= vw + 9'd1; bs <= B_SLEN; end
            B_SLEN: begin vbl_ram[vw] <= vb_rec_len; vw <= vw + 9'd1; build_k <= 4'd0; bs <= B_OTAG; end
            B_OTAG: begin vbl_ram[vw] <= 8'h06; vw <= vw + 9'd1; bs <= B_OLEN; end
            B_OLEN: begin vbl_ram[vw] <= cur_oid_len; vw <= vw + 9'd1; build_k <= 4'd0; bs <= B_OID; end
            B_OID: begin
                vbl_ram[vw] <= cur_oid_byte; vw <= vw + 9'd1;
                if (({1'b0, build_k} + 5'd1) >= {1'b0, cur_oid_len}) begin
                    build_k <= 4'd0; bs <= B_VTAG;
                end else build_k <= build_k + 4'd1;
            end
            B_VTAG: begin vbl_ram[vw] <= cur_val_tag; vw <= vw + 9'd1; bs <= B_VLEN; end
            B_VLEN: begin vbl_ram[vw] <= cur_val_len; vw <= vw + 9'd1; build_k <= 4'd0;
                            if (cur_val_len == 0) bs <= B_DONE; else bs <= B_VAL; end
            B_VAL: begin
                vbl_ram[vw] <= cur_val_byte; vw <= vw + 9'd1;
                if (({1'b0, build_k} + 5'd1) >= {1'b0, cur_val_len}) begin
                    build_k <= 4'd0; bs <= B_DONE;
                end else build_k <= build_k + 4'd1;
            end
            B_DONE: begin
                if (build_vb + 3'd1 < out_count) begin
                    build_vb <= build_vb + 3'd1;
                    bs <= B_SEQ;
                end else begin
                    vlen_r <= vw;
                    header_toggle <= ~header_toggle;
                    bs <= B_IDLE;
                end
            end
            default: bs <= B_IDLE;
            endcase
        end
    end

    // =========================================================================
    // BER 长度与响应头
    // =========================================================================
    function [1:0] enc_octets;
        input [9:0] value;
        begin enc_octets = (value < 10'd128) ? 2'd1 : 2'd2; end
    endfunction

    reg [7:0]  rid_r [0:4];
    reg [7:0]  rid_len_r;
    reg [7:0]  ver_r;
    reg        set_r;
    reg        too_big_r;
    reg [7:0]  err_status_r, err_index_r;

    wire [9:0] rid_tlv_w = 10'd2 + rid_len_r;
    wire [9:0] l3_w = 10'd1 + {8'h0, enc_octets(vlen_r)} + vlen_r;
    wire [9:0] vbl_container_w = l3_w;
    wire [9:0] l2_w = rid_tlv_w + 10'd6 + vbl_container_w;
    wire [9:0] pdu_container_w = 10'd1 + {8'h0, enc_octets(l2_w)} + l2_w;
    wire [9:0] l1_w = 10'd3 + 10'd8 + pdu_container_w;
    wire [9:0] total_w = 10'd1 + {8'h0, enc_octets(l1_w)} + l1_w;

    reg [7:0]  hbuf [0:31];
    reg [4:0]  hw, hw_r;
    reg [9:0]  total_r;
    reg [3:0]  hs, hk;
    reg        header_toggle_seen;
    localparam [3:0] H_IDLE=0, H_SEQ=1, H_SEQL=2, H_VER=3, H_COMM=4,
                     H_PTAG=5, H_PLEN=6, H_RID=7, H_ERR=8,
                     H_VTAG=9, H_VLEN=10, H_DONE=11;
    reg        streaming;
    reg [8:0]  stream_p;

    always @(*) begin
        vbl_raddr = 9'd0;
        if (streaming && (stream_p >= {4'b0, hw_r}) &&
            ((stream_p - hw_r + 9'd1) < vlen_r))
            vbl_raddr = stream_p - hw_r + 9'd1;
    end

    always @(posedge clk) begin
        if (reset) begin
            hs <= H_IDLE; hw <= 5'd0; hk <= 4'd0; hw_r <= 5'd0;
            header_toggle_seen <= 1'b0;
            total_r <= 10'd0; streaming <= 1'b0; stream_p <= 9'd0;
            resp_valid <= 1'b0; resp_data <= 8'd0; resp_last <= 1'b0;
            resp_begin <= 1'b0; resp_cnt <= 16'd0;
        end else begin
            resp_valid <= 1'b0;
            resp_last  <= 1'b0;
            resp_begin <= 1'b0;

            if (streaming) begin
                if (stream_p < total_r) begin
                    resp_valid <= 1'b1;
                    resp_data  <= (stream_p < {4'b0, hw_r}) ? hbuf[stream_p[4:0]] : vbl_q;
                    resp_begin <= (stream_p == 9'd0);
                    resp_last  <= (stream_p == (total_r - 10'd1));
                    stream_p   <= stream_p + 9'd1;
                    if (stream_p == (total_r - 10'd1))
                        resp_cnt <= resp_cnt + 16'd1;
                end else begin
                    streaming <= 1'b0;
                    stream_p  <= 9'd0;
                end
            end else begin
                case (hs)
                H_IDLE: begin
                    if (header_toggle != header_toggle_seen) begin
                        header_toggle_seen <= header_toggle;
                        hw <= 5'd1; hk <= 4'd0;
                        hbuf[0] <= 8'h30;
                        hs <= H_SEQL;
                    end
                end
                H_SEQL: begin
                    if (l1_w >= 10'd128) begin
                        if (hk == 4'd0) begin
                            hbuf[hw] <= 8'h81; hw <= hw + 5'd1; hk <= 4'd1;
                        end else begin
                            hbuf[hw] <= l1_w[7:0]; hw <= hw + 5'd1;
                            hk <= 4'd0; hs <= H_VER;
                        end
                    end else begin
                        hbuf[hw] <= l1_w[7:0]; hw <= hw + 5'd1;
                        hk <= 4'd0; hs <= H_VER;
                    end
                end
                H_VER: begin
                    case (hk)
                        4'd0: hbuf[hw] <= 8'h02;
                        4'd1: hbuf[hw] <= 8'h01;
                        default: hbuf[hw] <= ver_r;
                    endcase
                    hw <= hw + 5'd1;
                    if (hk == 4'd2) begin hk <= 4'd0; hs <= H_COMM; end else hk <= hk + 4'd1;
                end
                H_COMM: begin
                    case (hk[2:0])
                        3'd0: hbuf[hw] <= 8'h04;
                        3'd1: hbuf[hw] <= 8'd6;
                        3'd2: hbuf[hw] <= COMMUNITY[47:40];
                        3'd3: hbuf[hw] <= COMMUNITY[39:32];
                        3'd4: hbuf[hw] <= COMMUNITY[31:24];
                        3'd5: hbuf[hw] <= COMMUNITY[23:16];
                        3'd6: hbuf[hw] <= COMMUNITY[15:8];
                        default: hbuf[hw] <= COMMUNITY[7:0];
                    endcase
                    hw <= hw + 5'd1;
                    if (hk == 4'd7) begin hk <= 4'd0; hs <= H_PTAG; end else hk <= hk + 4'd1;
                end
                H_PTAG: begin hbuf[hw] <= 8'hA2; hw <= hw + 5'd1; hk <= 4'd0; hs <= H_PLEN; end
                H_PLEN: begin
                    if (l2_w >= 10'd128) begin
                        if (hk == 4'd0) begin hbuf[hw] <= 8'h81; hw <= hw + 5'd1; hk <= 4'd1; end
                        else begin hbuf[hw] <= l2_w[7:0]; hw <= hw + 5'd1;
                                   hk <= 4'd0; hs <= H_RID; end
                    end else begin hbuf[hw] <= l2_w[7:0]; hw <= hw + 5'd1;
                               hk <= 4'd0; hs <= H_RID; end
                end
                H_RID: begin
                    if (hk == 4'd0) hbuf[hw] <= 8'h02;
                    else if (hk == 4'd1) hbuf[hw] <= rid_len_r;
                    else hbuf[hw] <= rid_r[hk - 4'd2];
                    hw <= hw + 5'd1;
                    if (hk == (rid_len_r + 4'd1)) begin hk <= 4'd0; hs <= H_ERR; end
                    else hk <= hk + 4'd1;
                end
                H_ERR: begin
                    case (hk)
                        4'd0: hbuf[hw] <= 8'h02;
                        4'd1: hbuf[hw] <= 8'h01;
                        4'd2: hbuf[hw] <= err_status_r;
                        4'd3: hbuf[hw] <= 8'h02;
                        4'd4: hbuf[hw] <= 8'h01;
                        default: hbuf[hw] <= err_index_r;
                    endcase
                    hw <= hw + 5'd1;
                    if (hk == 4'd5) begin hk <= 4'd0; hs <= H_VTAG; end else hk <= hk + 4'd1;
                end
                H_VTAG: begin hbuf[hw] <= 8'h30; hw <= hw + 5'd1; hk <= 4'd0; hs <= H_VLEN; end
                H_VLEN: begin
                    if (vlen_r >= 10'd128) begin
                        if (hk == 4'd0) begin hbuf[hw] <= 8'h81; hw <= hw + 5'd1; hk <= 4'd1; end
                        else begin hbuf[hw] <= vlen_r[7:0]; hw <= hw + 5'd1;
                                   hk <= 4'd0; hs <= H_DONE; end
                    end else begin hbuf[hw] <= vlen_r[7:0]; hw <= hw + 5'd1;
                               hk <= 4'd0; hs <= H_DONE; end
                end
                H_DONE: begin
                    hw_r <= hw; total_r <= total_w;
                    streaming <= 1'b1; stream_p <= 9'd0; hs <= H_IDLE;
                end
                default: hs <= H_IDLE;
                endcase
            end
            vbl_q <= vbl_ram[vbl_raddr];
        end
    end

    wire req_engine_idle = (bs == B_IDLE) && (hs == H_IDLE) && !streaming &&
                           (build_toggle == build_toggle_seen) &&
                           (header_toggle == header_toggle_seen);

    // =========================================================================
    // 请求扫描与解析启动
    // =========================================================================
    reg parse_pending;
    reg nosuch_count_delay;
    reg tstreaming;
    reg [15:0] unknown_req_cnt;
    integer uj;
    always @(*) begin
        unknown_req_cnt = 16'd0;
        for (uj = 0; uj < 4; uj = uj + 1)
            if (is_get && vb_present[uj] && !req_hit[uj])
                unknown_req_cnt = unknown_req_cnt + 16'd1;
    end

    always @(posedge clk) begin
        if (reset) begin
            scan_i <= 8'd0; scan_end <= 8'd0; scanning <= 1'b0;
            parse_ready <= 1'b0; parse_pending <= 1'b0; req_len_r <= 9'd0;
            build_toggle <= 1'b0;
            req_cnt <= 16'd0; drop_cnt <= 16'd0; no_such_cnt <= 16'd0;
            nosuch_count_delay <= 1'b0;
            rid_len_r <= 8'd0; ver_r <= 8'd0; set_r <= 1'b0;
            too_big_r <= 1'b0; err_status_r <= 8'd0; err_index_r <= 8'd0;
            for (uj = 0; uj < 5; uj = uj + 1) rid_r[uj] <= 8'd0;
            for (uj = 0; uj < 4; uj = uj + 1) req_oid_len[uj] <= 4'd0;
        end else begin
            if (nosuch_count_delay) begin
                no_such_cnt <= no_such_cnt + {13'd0, out_nosuch_count};
                nosuch_count_delay <= 1'b0;
            end
            if (req_last && ((wrp < 9'd256) || (wrp == 9'd256)) && req_engine_idle && !tstreaming)
                parse_pending <= 1'b1;

            if (scanning) begin
                rh[scan_i[6:0]] <= rxb_q;
                if ((scan_i + 8'd1) >= scan_end) begin
                    scanning <= 1'b0;
                    parse_ready <= 1'b1;
                end else scan_i <= scan_i + 8'd1;
            end

            if (parse_pending && !scanning && (bs == B_IDLE)) begin
                parse_pending <= 1'b0;
                req_cnt <= req_cnt + 16'd1;
                req_len_r <= (wrp > 9'd128) ? 9'd129 : wrp;
                scan_end <= (wrp > 9'd128) ? 8'd128 : wrp[7:0];
                scan_i <= 8'd0;
                scanning <= 1'b1;
            end else if (parse_ready) begin
                parse_ready <= 1'b0;
                if (!msg_ok) begin
                    drop_cnt <= drop_cnt + 16'd1;
                end else begin
                    for (uj = 0; uj < 4; uj = uj + 1) begin
                        req_oid_len[uj] <= (uj < req_count) ? oid_len_v[uj][3:0] : 4'd0;
                        for (hn = 0; hn < 16; hn = hn + 1)
                            req_oid[uj][hn] <= (uj < req_count) ?
                                rh[oid_pos_v[uj] + 8'd2 + hn[7:0]] : 8'h00;
                    end
                    for (uj = 0; uj < 5; uj = uj + 1)
                        rid_r[uj] <= (uj < rid_len) ? rh[p_rid + 8'd2 + uj] : 8'h00;
                    rid_len_r <= rid_len;
                    ver_r <= ver_num;
                    set_r <= is_set;
                    too_big_r <= too_big;
                    err_status_r <= too_big ? 8'd1 : (is_set ? 8'd5 : 8'd0);
                    err_index_r  <= is_set ? 8'd1 : 8'd0;
                    build_toggle <= ~build_toggle;
                    nosuch_count_delay <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // v2c Trap-PDU：sysUpTime.0 + snmpTrapOID.0 + afdxVlFault.0
    // =========================================================================
    (* ramstyle = "M4K", no_rw_check *) reg [7:0] ttb [0:127];
    reg [7:0]  ttb_q, tt_raddr;
    reg [7:0]  tsp;
    reg [6:0]  twp;
    reg        trap_building, trap_pending;
    reg [7:0]  fault_q;
    reg        fault_seen;
    reg [7:0]  trap_byte_w;
    wire       fault_changed = (vl_fault != fault_q);

    always @(*) begin
        case (twp)
            7'd0: trap_byte_w=8'h30; 7'd1: trap_byte_w=8'd88;
            7'd2: trap_byte_w=8'h02; 7'd3: trap_byte_w=8'h01; 7'd4: trap_byte_w=8'h01;
            7'd5: trap_byte_w=8'h04; 7'd6: trap_byte_w=8'd6;
            7'd7: trap_byte_w=COMMUNITY[47:40]; 7'd8: trap_byte_w=COMMUNITY[39:32];
            7'd9: trap_byte_w=COMMUNITY[31:24]; 7'd10: trap_byte_w=COMMUNITY[23:16];
            7'd11: trap_byte_w=COMMUNITY[15:8]; 7'd12: trap_byte_w=COMMUNITY[7:0];
            7'd13: trap_byte_w=8'hA7; 7'd14: trap_byte_w=8'd75;
            7'd15: trap_byte_w=8'h02; 7'd16: trap_byte_w=8'h04;
            7'd17: trap_byte_w=8'h00; 7'd18: trap_byte_w=8'h00;
            7'd19: trap_byte_w=8'h00; 7'd20: trap_byte_w=8'h01;
            7'd21: trap_byte_w=8'h02; 7'd22: trap_byte_w=8'h01; 7'd23: trap_byte_w=8'h00;
            7'd24: trap_byte_w=8'h02; 7'd25: trap_byte_w=8'h01; 7'd26: trap_byte_w=8'h00;
            7'd27: trap_byte_w=8'h30; 7'd28: trap_byte_w=8'd61;
            7'd29: trap_byte_w=8'h30; 7'd30: trap_byte_w=8'd16;
            7'd31: trap_byte_w=8'h06; 7'd32: trap_byte_w=8'd8;
            7'd33: trap_byte_w=8'h2B; 7'd34: trap_byte_w=8'h06;
            7'd35: trap_byte_w=8'h01; 7'd36: trap_byte_w=8'h02;
            7'd37: trap_byte_w=8'h01; 7'd38: trap_byte_w=8'h01;
            7'd39: trap_byte_w=8'h03; 7'd40: trap_byte_w=8'h00;
            7'd41: trap_byte_w=8'h43; 7'd42: trap_byte_w=8'd4;
            7'd43: trap_byte_w=sys_uptime[31:24]; 7'd44: trap_byte_w=sys_uptime[23:16];
            7'd45: trap_byte_w=sys_uptime[15:8]; 7'd46: trap_byte_w=sys_uptime[7:0];
            7'd47: trap_byte_w=8'h30; 7'd48: trap_byte_w=8'd24;
            7'd49: trap_byte_w=8'h06; 7'd50: trap_byte_w=8'd10;
            7'd51: trap_byte_w=8'h2B; 7'd52: trap_byte_w=8'h06;
            7'd53: trap_byte_w=8'h01; 7'd54: trap_byte_w=8'h06;
            7'd55: trap_byte_w=8'h03; 7'd56: trap_byte_w=8'h01;
            7'd57: trap_byte_w=8'h01; 7'd58: trap_byte_w=8'h04;
            7'd59: trap_byte_w=8'h01; 7'd60: trap_byte_w=8'h00;
            7'd61: trap_byte_w=8'h06; 7'd62: trap_byte_w=8'd10;
            7'd63: trap_byte_w=8'h2B; 7'd64: trap_byte_w=8'h06;
            7'd65: trap_byte_w=8'h01; 7'd66: trap_byte_w=8'h04;
            7'd67: trap_byte_w=8'h01; 7'd68: trap_byte_w=8'h86;
            7'd69: trap_byte_w=8'h8D; 7'd70: trap_byte_w=8'h1F;
            7'd71: trap_byte_w=8'h00; 7'd72: trap_byte_w=8'h01;
            7'd73: trap_byte_w=8'h30; 7'd74: trap_byte_w=8'd15;
            7'd75: trap_byte_w=8'h06; 7'd76: trap_byte_w=8'd10;
            7'd77: trap_byte_w=8'h2B; 7'd78: trap_byte_w=8'h06;
            7'd79: trap_byte_w=8'h01; 7'd80: trap_byte_w=8'h04;
            7'd81: trap_byte_w=8'h01; 7'd82: trap_byte_w=8'h86;
            7'd83: trap_byte_w=8'h8D; 7'd84: trap_byte_w=8'h1F;
            7'd85: trap_byte_w=8'h06; 7'd86: trap_byte_w=8'h00;
            7'd87: trap_byte_w=8'h02; 7'd88: trap_byte_w=8'h01;
            7'd89: trap_byte_w=vl_fault;
            default: trap_byte_w=8'h00;
        endcase
    end

    always @(*) begin
        tt_raddr = tstreaming ? (tsp + 8'd1) : 8'd0;
    end

    always @(posedge clk) begin
        if (reset) begin
            tstreaming<=1'b0; tsp<=8'd0; twp<=7'd0;
            trap_building<=1'b0; trap_pending<=1'b0;
            fault_q<=8'h00; fault_seen<=1'b0;
            trap_valid<=1'b0; trap_data<=8'd0; trap_last<=1'b0;
            trap_begin<=1'b0; trap_cnt<=16'd0;
        end else begin
            trap_valid<=1'b0; trap_last<=1'b0; trap_begin<=1'b0;
            fault_q<=vl_fault;
            if (!fault_seen) fault_seen<=1'b1;
            else if (fault_changed && !trap_pending && !tstreaming)
                trap_pending<=1'b1;

            if (tstreaming) begin
                if (tsp < 8'd90) begin
                    trap_valid<=1'b1; trap_data<=ttb_q;
                    trap_begin<=(tsp==8'd0); trap_last<=(tsp==8'd89);
                    tsp<=tsp+8'd1;
                    if (tsp==8'd89) trap_cnt<=trap_cnt+16'd1;
                end else begin tstreaming<=1'b0; tsp<=8'd0; end
            end else if (trap_building) begin
                ttb[twp]<=trap_byte_w;
                if (twp==7'd89) begin trap_building<=1'b0; tstreaming<=1'b1; tsp<=8'd0; end
                else twp<=twp+7'd1;
            end else if (trap_pending && req_engine_idle && (bs==B_IDLE) && (hs==H_IDLE)) begin
                trap_pending<=1'b0; twp<=7'd0; trap_building<=1'b1;
            end
            ttb_q<=ttb[tt_raddr];
        end
    end

endmodule
