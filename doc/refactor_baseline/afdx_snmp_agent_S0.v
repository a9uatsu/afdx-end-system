// =============================================================================
// 文件名  : afdx_snmp_agent.v
// 模块    : afdx_snmp_agent
// 功能    : AFDX 端系统 SNMP v2c 代理（GetRequest -> GetResponse）
//
// 协议子集（RFC 3416 / RFC 3418）：
//   请求：SEQUENCE { version(0=v1, 1=v2c), community,
//                    GetRequest[A0] { request-id, error-status, error-index,
//                                      varbind-list { varbind { OID, NULL } } } }
//   响应：SEQUENCE { version, community,
//                    GetResponse[A2] { 原 request-id, error=0, index=0,
//                                      varbind { 原 OID, 值 } } }
//
// 约束：仅支持短格式长度（单字节，报文 < 128 字节）；snmpget 单 OID 报文典型满足。
//       社区名 "public"；GetRequest(A0) 支持；其他 PDU/社区错误静默丢弃并计数。
//       未知 OID 返回 noSuchObject(0x80)。
//
// 10 个标量对象：
//   1.3.6.1.2.1.1.1.0 sysDescr      OCTET STRING
//   1.3.6.1.2.1.1.3.0 sysUpTime     TimeTicks
//   1.3.6.1.2.1.1.5.0 sysName       OCTET STRING
//   1.3.6.1.4.1.<ENT>.1.0 txFrames      Counter32
//   1.3.6.1.4.1.<ENT>.2.0 rxFrames      Counter32
//   1.3.6.1.4.1.<ENT>.3.0 rxErrors      Counter32
//   1.3.6.1.4.1.<ENT>.4.0 duplicates    Counter32
//   1.3.6.1.4.1.<ENT>.5.0 icErrors      Counter32
//   1.3.6.1.4.1.<ENT>.6.0 vlFault       INTEGER
//   1.3.6.1.4.1.<ENT>.7.0 vlCapacity    INTEGER
// =============================================================================
`include "afdx_defs.vh"

module afdx_snmp_agent #(
    parameter [47:0] COMMUNITY  = 48'h7075626c6963,  // "public"
    // 企业号 99999（0x1869F）在 OID 中编码为 86 8D 1F，见 mib_oid_byte()
    parameter [7:0]  SYS_NAME_LEN  = 8'd7,
    parameter [7:0]  SYS_DESCR_LEN = 8'd16
) (
    input  wire        clk,
    input  wire        reset,
    // ---- MIB 数据源 ----
    input  wire [31:0] sys_uptime,
    input  wire [31:0] cnt_tx_frames,
    input  wire [31:0] cnt_rx_frames,
    input  wire [31:0] cnt_rx_errors,
    input  wire [31:0] cnt_dup,
    input  wire [31:0] cnt_ic_err,
    input  wire [7:0]  vl_fault,
    input  wire [15:0] vl_capacity,
    // ---- 请求写入 ----
    input  wire        req_wr,
    input  wire [7:0]  req_data,
    input  wire        req_last,
    input  wire        req_start,
    // ---- 响应流 ----
    output reg         resp_valid,
    output reg  [7:0]  resp_data,
    output reg         resp_last,
    output reg         resp_begin,
    // ---- 统计 ----
    output reg  [15:0] req_cnt,
    output reg  [15:0] resp_cnt,
    output reg  [15:0] drop_cnt,
    output reg  [15:0] no_such_cnt,
    // ---- Trap（v2c Trap-PDU） ----
    output reg         trap_valid,
    output reg  [7:0]  trap_data,
    output reg         trap_last,
    output reg         trap_begin,
    output reg  [15:0] trap_cnt
);

    // =========================================================================
    // 请求缓冲
    // =========================================================================
    reg [7:0]  rxb [0:255];
    reg [8:0]  wrp;

    always @(posedge clk) begin
        if (reset) begin
            wrp <= 9'd0;
        end else if (req_start) begin
            wrp <= 9'd0;
        end else if (req_wr) begin
            if (wrp < 256) rxb[wrp] <= req_data;
            wrp <= wrp + 9'd1;
        end
    end

    // =========================================================================
    // 报文结构偏移（短格式长度）
    //   0:30 1:len | 2:02 3:01 4:ver | p_comm:04 len comm...
    //   p_pdu:A0 len | p_rid:02 len rid... | +3 error-status | +3 error-index
    //   p_vbl:30 len | p_vb:30 len | p_oid:06 len oid... | p_null:05 00
    // =========================================================================
    wire [8:0] p_comm = 9'd2 + 9'd2 + 9'd1;                       // 版本 TLV 固定 3 字节
    wire [8:0] p_pdu  = p_comm + 9'd2 + {1'b0, rxb[p_comm + 9'd1]};
    wire [8:0] p_rid  = p_pdu + 9'd2;
    wire [8:0] p_est  = p_rid + 9'd2 + {1'b0, rxb[p_rid + 9'd1]};
    wire [8:0] p_eid  = p_est + 9'd3;
    wire [8:0] p_vbl  = p_eid + 9'd3;
    wire [8:0] p_vb   = p_vbl + 9'd2;
    wire [8:0] p_oid  = p_vb + 9'd2;
    wire [8:0] p_null = p_oid + 9'd2 + {1'b0, rxb[p_oid + 9'd1]};

    wire [7:0] comm_len = rxb[p_comm + 9'd1];
    wire [7:0] rid_len  = rxb[p_rid + 9'd1];
    wire [7:0] oid_len  = rxb[p_oid + 9'd1];
    wire [7:0] ver_num  = rxb[4];

    // =========================================================================
    // 合法性检查
    // =========================================================================
    wire ok_ver  = (rxb[0] == 8'h30) && (rxb[2] == 8'h02) &&
                   (rxb[3] == 8'h01) && (ver_num <= 8'h01);
    wire ok_comm = (rxb[p_comm] == 8'h04) && (comm_len == 8'd6) &&
                   ({rxb[p_comm+9'd2], rxb[p_comm+9'd3], rxb[p_comm+9'd4],
                     rxb[p_comm+9'd5], rxb[p_comm+9'd6], rxb[p_comm+9'd7]} == COMMUNITY);
    wire is_getnext = (rxb[p_pdu] == 8'hA1);
    wire is_set     = (rxb[p_pdu] == 8'hA3);
    wire ok_pdu  = (rxb[p_pdu] == 8'hA0) || is_getnext || is_set;
    wire ok_rid  = (rxb[p_rid] == 8'h02) && (rid_len >= 8'd1) && (rid_len <= 8'd5);
    wire ok_est  = (rxb[p_est] == 8'h02) && (rxb[p_est+9'd1] == 8'd1);
    wire ok_eid  = (rxb[p_eid] == 8'h02) && (rxb[p_eid+9'd1] == 8'd1);
    wire ok_vbl  = (rxb[p_vbl] == 8'h30);
    wire ok_vb   = (rxb[p_vb]  == 8'h30);
    wire ok_oid  = (rxb[p_oid] == 8'h06) && (oid_len >= 8'd2) && (oid_len <= 8'd16);
    wire ok_null = is_set ? 1'b1 : (rxb[p_null] == 8'h05);

    wire msg_ok = ok_ver && ok_comm && ok_pdu && ok_rid && ok_est &&
                  ok_eid && ok_vbl && ok_vb && ok_oid && ok_null;

    // =========================================================================
    // MIB 表：10 个标量对象
    // =========================================================================
    localparam [3:0] MIB_N = 4'd10;

    function [3:0] mib_family;          // 0=1.3.6.1.2.1, 1=1.3.6.1.4.1.<ent>
        input [3:0] e;
        begin
            mib_family = (e < 4'd3) ? 4'd0 : 4'd1;
        end
    endfunction

    function [7:0] mib_sub;
        input [3:0] e;
        begin
            case (e)
                4'd0:    mib_sub = 8'd1;      // .1.1.0
                4'd1:    mib_sub = 8'd3;      // .1.3.0
                4'd2:    mib_sub = 8'd5;      // .1.5.0
                default: mib_sub = {4'h0, e} - 8'd2;   // 3..9 -> 1..7
            endcase
        end
    endfunction

    function [3:0] mib_type;            // 0=INTEGER 1=Counter32 2=TimeTicks 3=OCTET STRING
        input [3:0] e;
        begin
            case (e)
                4'd0: mib_type = 4'd3;
                4'd1: mib_type = 4'd2;
                4'd2: mib_type = 4'd3;
                4'd3, 4'd4, 4'd5, 4'd6, 4'd7: mib_type = 4'd1;
                default: mib_type = 4'd0;
            endcase
        end
    endfunction

    function [8:0] mib_oid_len;
        input [3:0] e;
        begin
            mib_oid_len = (e < 4'd3) ? 9'd8 : 9'd10;
        end
    endfunction

    function [7:0] mib_oid_byte;
        input [3:0] e;
        input [3:0] k;
        reg   [7:0] sub;
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

    // =========================================================================
    // 请求 OID 提取与查表（组合）
    // =========================================================================
    reg [7:0] oid_r [0:15];
    reg [3:0] mib_hit;
    reg       mib_found;
    reg       match_ok;
    reg [3:0] next_idx;
    reg       next_found;
    reg       cmp_gt;
    reg       cmp_decided;
    integer   m, n;

    always @(*) begin
        for (m = 0; m < 16; m = m + 1)
            oid_r[m] = (m < oid_len) ? rxb[p_oid + 9'd2 + m] : 8'h00;
    end

    always @(*) begin
        mib_found = 1'b0;
        mib_hit   = 4'd0;
        for (m = MIB_N - 1; m >= 0; m = m - 1) begin
            match_ok = (mib_oid_len(m[3:0]) == {1'b0, oid_len});
            for (n = 0; n < 16; n = n + 1) begin
                if (n < oid_len)
                    match_ok = match_ok && (oid_r[n] == mib_oid_byte(m[3:0], n[3:0]));
            end
            if (match_ok) begin
                mib_found = 1'b1;
                mib_hit   = m[3:0];
            end
        end
    end

    // =========================================================================
    // 值选择
    // GetNext：找第一个严格大于请求 OID 的条目（MIB 表按 OID 升序）
    always @(*) begin
        next_found = 1'b0;
        next_idx   = 4'd0;
        for (m = MIB_N - 1; m >= 0; m = m - 1) begin
            cmp_gt      = 1'b0;
            cmp_decided = 1'b0;
            for (n = 0; n < 16; n = n + 1) begin
                if (!cmp_decided && (n < oid_len) && (n < mib_oid_len(m[3:0]))) begin
                    if (oid_r[n] < mib_oid_byte(m[3:0], n[3:0])) begin
                        cmp_gt      = 1'b1;
                        cmp_decided = 1'b1;
                    end else if (oid_r[n] > mib_oid_byte(m[3:0], n[3:0])) begin
                        cmp_gt      = 1'b0;
                        cmp_decided = 1'b1;
                    end
                end
            end
            if (!cmp_decided)
                cmp_gt = (mib_oid_len(m[3:0]) > {1'b0, oid_len});
            if (cmp_gt) begin
                next_found = 1'b1;   // 倒序扫描：最后赋值即最小索引
                next_idx   = m[3:0];
            end
        end
    end

    wire        sel_valid = is_getnext ? next_found : mib_found;
    wire [3:0]  sel_idx   = is_getnext ? next_idx   : mib_hit;
    wire [8:0]  next_oid_len_w = mib_oid_len(next_idx);

    // =========================================================================
    reg [31:0] val_num;
    reg [7:0]  val_tag;
    reg        val_is_str;
    reg [7:0]  val_len;
    reg [7:0]  val_str [0:15];
    integer    v;

    always @(*) begin
        val_num    = 32'h0;
        val_is_str = 1'b0;
        val_tag    = 8'h02;
        val_len    = 8'd0;
        for (v = 0; v < 16; v = v + 1) val_str[v] = 8'h00;

        if (is_set) begin
            val_tag = 8'h05;     // 只读 MIB：varbind 以 NULL 回显
            val_len = 8'd0;
        end else if (sel_valid) begin
            case (sel_idx)
                4'd0: begin   // sysDescr "AFDX-ES EQ6HL130"
                    val_is_str = 1'b1; val_tag = 8'h04; val_len = SYS_DESCR_LEN;
                    val_str[0]=8'h41;  val_str[1]=8'h46;  val_str[2]=8'h44;  val_str[3]=8'h58;
                    val_str[4]=8'h2D;  val_str[5]=8'h45;  val_str[6]=8'h53;  val_str[7]=8'h20;
                    val_str[8]=8'h45;  val_str[9]=8'h51;  val_str[10]=8'h36; val_str[11]=8'h48;
                    val_str[12]=8'h4C; val_str[13]=8'h31; val_str[14]=8'h33; val_str[15]=8'h30;
                end
                4'd1: begin val_tag = 8'h43; val_len = 8'd4; val_num = sys_uptime;    end
                4'd2: begin   // sysName "afdx-es"
                    val_is_str = 1'b1; val_tag = 8'h04; val_len = SYS_NAME_LEN;
                    val_str[0]=8'h61; val_str[1]=8'h66; val_str[2]=8'h64;
                    val_str[3]=8'h78; val_str[4]=8'h2D; val_str[5]=8'h65; val_str[6]=8'h73;
                end
                4'd3: begin val_tag = 8'h41; val_len = 8'd4; val_num = cnt_tx_frames; end
                4'd4: begin val_tag = 8'h41; val_len = 8'd4; val_num = cnt_rx_frames; end
                4'd5: begin val_tag = 8'h41; val_len = 8'd4; val_num = cnt_rx_errors; end
                4'd6: begin val_tag = 8'h41; val_len = 8'd4; val_num = cnt_dup;       end
                4'd7: begin val_tag = 8'h41; val_len = 8'd4; val_num = cnt_ic_err;    end
                4'd8: begin   // vlFault：INTEGER，按需 1 或 2 字节
                    val_tag = 8'h02;
                    val_num = {24'h0, vl_fault};
                    val_len = (vl_fault[7]) ? 8'd2 : 8'd1;
                end
                default: begin val_tag = 8'h02; val_len = 8'd2;
                               val_num = {16'h0, vl_capacity}; end
            endcase
        end else begin
            val_tag = is_getnext ? 8'h82 : 8'h80;   // endOfMibView : noSuchObject
            val_len = 8'd0;
        end
    end

    // =========================================================================
    // 响应长度（全部短格式）
    // =========================================================================
    reg [7:0]  rid_len_r, oid_len_r, val_len_r, val_tag_r;   // 需在长度计算前声明
    // 使用"锁存后"的长度：GetNext 响应 OID 长度与请求不同
    wire [8:0] rid_tlv = 9'd2 + {1'b0, rid_len_r};
    wire [8:0] oid_tlv = 9'd2 + {1'b0, oid_len_r};
    wire [8:0] val_tlv = 9'd2 + {1'b0, val_len_r};
    wire [8:0] l4 = oid_tlv + val_tlv;
    wire [8:0] l3 = l4 + 9'd2;
    wire [8:0] l2 = rid_tlv + 9'd3 + 9'd3 + l3 + 9'd2;
    wire [8:0] l1 = 9'd3 + 9'd8 + l2 + 9'd2;
    wire [8:0] resp_total = l1 + 9'd2;

    // =========================================================================
    // 组包状态机
    // =========================================================================
    reg [7:0]  txb [0:255];
    reg [7:0]  wp;
    reg [2:0]  st;
    reg [4:0]  k;
    reg [8:0]  stream_p;
    reg        parse_pending;
    reg        tstreaming;        // Trap 流出中（供响应侧互斥判断，需先声明）

    localparam [2:0] S_IDLE = 3'd0, S_PREP = 3'd1, S_VER = 3'd2, S_COMM = 3'd3,
                     S_PDU  = 3'd4, S_RID  = 3'd5, S_TAIL = 3'd6, S_OID = 3'd7;
    // S_TAIL 一次性写 error-status/error-index/varbind 头；S_OID 写 OID 与值；
    // 之后进入流输出（用 st=3'd0 且 stream_p 判断）

    reg [7:0]  rid_r [0:4];
    reg [7:0]  oid_s [0:15];
    reg [31:0] val_num_r;
    reg [7:0]  val_str_r [0:15];
    reg        val_is_str_r;
    reg        streaming;
    integer    q;

    always @(posedge clk) begin
        if (reset) begin
            st            <= S_IDLE;
            wp            <= 8'd0;
            k             <= 5'd0;
            parse_pending <= 1'b0;
            streaming     <= 1'b0;
            resp_valid    <= 1'b0;
            resp_data     <= 8'd0;
            resp_last     <= 1'b0;
            resp_begin    <= 1'b0;
            req_cnt       <= 16'd0;
            resp_cnt      <= 16'd0;
            drop_cnt      <= 16'd0;
            no_such_cnt   <= 16'd0;
            stream_p      <= 9'd0;
        end else begin
            resp_valid <= 1'b0;
            resp_last  <= 1'b0;
            resp_begin <= 1'b0;

            if (req_last && !streaming && !tstreaming && (st == S_IDLE))
                parse_pending <= 1'b1;

            // ---------------- 流输出 ----------------
            if (streaming) begin
                if (stream_p < resp_total) begin
                    resp_valid <= 1'b1;
                    resp_data  <= txb[stream_p[7:0]];
                    resp_begin <= (stream_p == 9'd0);
                    resp_last  <= (stream_p == (resp_total - 9'd1));
                    stream_p   <= stream_p + 9'd1;
                    if (stream_p == (resp_total - 9'd1))
                        resp_cnt <= resp_cnt + 16'd1;
                end else begin
                    streaming <= 1'b0;
                    stream_p  <= 9'd0;
                end
            end else begin
                case (st)
                S_IDLE: begin
                    if (parse_pending) begin
                        parse_pending <= 1'b0;
                        req_cnt <= req_cnt + 16'd1;
                        if (!msg_ok) begin
                            drop_cnt <= drop_cnt + 16'd1;
                        end else begin
                            for (q = 0; q < 5; q = q + 1)
                                rid_r[q] <= (q < rid_len) ? rxb[p_rid + 9'd2 + q] : 8'h00;
                            for (q = 0; q < 16; q = q + 1)
                                oid_s[q] <= (is_getnext && next_found)
                                            ? ((q < mib_oid_len(next_idx))
                                               ? mib_oid_byte(next_idx, q[3:0]) : 8'h00)
                                            : ((q < oid_len) ? rxb[p_oid + 9'd2 + q] : 8'h00);
                            rid_len_r    <= rid_len;
                            oid_len_r    <= (is_getnext && next_found)
                                            ? next_oid_len_w[7:0] : oid_len;
                            val_len_r    <= val_len;
                            val_tag_r    <= val_tag;
                            val_num_r    <= val_num;
                            val_is_str_r <= val_is_str;
                            for (q = 0; q < 16; q = q + 1)
                                val_str_r[q] <= val_str[q];
                            if (!is_getnext && !mib_found)
                                no_such_cnt <= no_such_cnt + 16'd1;
                            st <= S_PREP;
                        end
                    end
                end

                S_PREP: begin
                    txb[0] <= 8'h30;
                    txb[1] <= l1[7:0];
                    wp     <= 8'd2;
                    st     <= S_VER;
                end

                S_VER: begin
                    txb[wp]       <= 8'h02;
                    txb[wp+8'd1]  <= 8'h01;
                    txb[wp+8'd2]  <= (ver_num == 8'h01) ? 8'h01 : 8'h00;
                    wp <= wp + 8'd3;
                    st <= S_COMM;
                end

                S_COMM: begin
                    txb[wp]       <= 8'h04;
                    txb[wp+8'd1]  <= 8'd6;
                    txb[wp+8'd2]  <= COMMUNITY[47:40];
                    txb[wp+8'd3]  <= COMMUNITY[39:32];
                    txb[wp+8'd4]  <= COMMUNITY[31:24];
                    txb[wp+8'd5]  <= COMMUNITY[23:16];
                    txb[wp+8'd6]  <= COMMUNITY[15:8];
                    txb[wp+8'd7]  <= COMMUNITY[7:0];
                    wp <= wp + 8'd8;
                    st <= S_PDU;
                end

                S_PDU: begin
                    txb[wp]      <= 8'hA2;
                    txb[wp+8'd1] <= l2[7:0];
                    wp <= wp + 8'd2;
                    k  <= 5'd0;
                    st <= S_RID;
                end

                S_RID: begin
                    if (k == 5'd0) begin
                        txb[wp]      <= 8'h02;
                        txb[wp+8'd1] <= rid_len_r;
                        wp <= wp + 8'd2;
                        k  <= 5'd1;
                    end else if (k <= rid_len_r) begin
                        txb[wp] <= rid_r[k - 5'd1];
                        wp <= wp + 8'd1;
                        k  <= k + 5'd1;
                    end else begin
                        st <= S_TAIL;
                        k  <= 5'd0;
                    end
                end

                S_TAIL: begin
                    // error-status(02 01 00) + error-index(02 01 00)
                    txb[wp]       <= 8'h02; txb[wp+8'd1] <= 8'h01;
                    txb[wp+8'd2]  <= is_set ? 8'd5 : 8'd0;          // notWritable
                    txb[wp+8'd3]  <= 8'h02; txb[wp+8'd4] <= 8'h01;
                    txb[wp+8'd5]  <= is_set ? 8'd1 : 8'd0;          // error-index
                    // varbind list + varbind
                    txb[wp+8'd6]  <= 8'h30; txb[wp+8'd7] <= l3[7:0];
                    txb[wp+8'd8]  <= 8'h30; txb[wp+8'd9] <= l4[7:0];
                    wp <= wp + 8'd10;
                    k  <= 5'd0;
                    st <= S_OID;
                end

                S_OID: begin
                    if (k == 5'd0) begin
                        txb[wp]      <= 8'h06;
                        txb[wp+8'd1] <= oid_len_r;
                        wp <= wp + 8'd2;
                        k  <= 5'd1;
                    end else if (k <= oid_len_r) begin
                        txb[wp] <= oid_s[k - 5'd1];
                        wp <= wp + 8'd1;
                        k  <= k + 5'd1;
                    end else if (k == (oid_len_r + 5'd1)) begin
                        // 值 TLV 头
                        txb[wp]      <= val_tag_r;
                        txb[wp+8'd1] <= val_len_r;
                        wp <= wp + 8'd2;
                        k  <= k + 5'd1;
                    end else if (k <= (oid_len_r + 5'd1 + val_len_r)) begin
                        // 值内容：vbase = k - (oid_len_r + 2)，取 32 位值的第 vbase 字节
                        if (val_is_str_r)
                            txb[wp] <= val_str_r[k - (oid_len_r + 5'd2)];
                        else begin
                            case (val_len_r)
                                8'd1:    txb[wp] <= val_num_r[7:0];
                                8'd2:    txb[wp] <= (k == (oid_len_r + 5'd2)) ? val_num_r[15:8]
                                                                             : val_num_r[7:0];
                                default: case (k - (oid_len_r + 5'd2))
                                             5'd0: txb[wp] <= val_num_r[31:24];
                                             5'd1: txb[wp] <= val_num_r[23:16];
                                             5'd2: txb[wp] <= val_num_r[15:8];
                                             default: txb[wp] <= val_num_r[7:0];
                                         endcase
                            endcase
                        end
                        wp <= wp + 8'd1;
                        k  <= k + 5'd1;
                    end else begin
                        streaming <= 1'b1;
                        stream_p  <= 9'd0;
                        st        <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
                endcase
            end
        end
    end

    // =========================================================================
    // Trap：v2c Trap-PDU（0xA7），固定长度 90 字节
    //   SEQUENCE { version, community,
    //     A7 { request-id=1, error=0, index=0,
    //          varbind-list { sysUpTime.0, snmpTrapOID.0, afdxVlFault.0 } } }
    //   触发：VL 故障位图发生变化
    // =========================================================================
    reg [7:0]  ttb [0:127];
    reg [3:0]  tstate;
    reg [7:0]  tsp;
    reg        trap_pending;
    reg [7:0]  fault_q;
    reg        fault_seen;      // 复位后首个采样不触发 Trap

    localparam [3:0] TT_IDLE = 4'd0, TT_OUT = 4'd1, TT_PDU = 4'd2,
                     TT_VB1  = 4'd3, TT_VB2 = 4'd4, TT_VB3 = 4'd5;

    wire fault_changed = (vl_fault != fault_q);

    always @(posedge clk) begin
        if (reset) begin
            tstate       <= TT_IDLE;
            tstreaming   <= 1'b0;
            tsp          <= 8'd0;
            trap_pending <= 1'b0;
            fault_q      <= 8'h00;
            fault_seen   <= 1'b0;
            trap_valid   <= 1'b0;
            trap_data    <= 8'd0;
            trap_last    <= 1'b0;
            trap_begin   <= 1'b0;
            trap_cnt     <= 16'd0;
        end else begin
            trap_valid <= 1'b0;
            trap_last  <= 1'b0;
            trap_begin <= 1'b0;
            fault_q    <= vl_fault;

            if (!fault_seen)
                fault_seen <= 1'b1;
            else if (fault_changed && !trap_pending && !tstreaming)
                trap_pending <= 1'b1;

            if (tstreaming) begin
                if (tsp < 8'd90) begin
                    trap_valid <= 1'b1;
                    trap_data  <= ttb[tsp];
                    trap_begin <= (tsp == 8'd0);
                    trap_last  <= (tsp == 8'd89);
                    tsp        <= tsp + 8'd1;
                    if (tsp == 8'd89) trap_cnt <= trap_cnt + 16'd1;
                end else begin
                    tstreaming <= 1'b0;
                    tsp        <= 8'd0;
                end
            end else begin
                case (tstate)
                TT_IDLE: begin
                    if (trap_pending && (st == S_IDLE) && !streaming) begin
                        trap_pending <= 1'b0;
                        ttb[0]  <= 8'h30; ttb[1]  <= 8'd88;              // SEQUENCE L1=88
                        ttb[2]  <= 8'h02; ttb[3]  <= 8'h01; ttb[4] <= 8'h01;
                        ttb[5]  <= 8'h04; ttb[6]  <= 8'd6;
                        ttb[7]  <= COMMUNITY[47:40]; ttb[8]  <= COMMUNITY[39:32];
                        ttb[9]  <= COMMUNITY[31:24]; ttb[10] <= COMMUNITY[23:16];
                        ttb[11] <= COMMUNITY[15:8];  ttb[12] <= COMMUNITY[7:0];
                        ttb[13] <= 8'hA7; ttb[14] <= 8'd75;              // Trap-PDU L2=75
                        tstate  <= TT_PDU;
                    end
                end
                TT_PDU: begin
                    ttb[15] <= 8'h02; ttb[16] <= 8'h04; ttb[17] <= 8'h00;
                    ttb[18] <= 8'h00; ttb[19] <= 8'h00; ttb[20] <= 8'h01;
                    ttb[21] <= 8'h02; ttb[22] <= 8'h01; ttb[23] <= 8'h00;
                    ttb[24] <= 8'h02; ttb[25] <= 8'h01; ttb[26] <= 8'h00;
                    ttb[27] <= 8'h30; ttb[28] <= 8'd61;              // varbind-list L3=61
                    tstate  <= TT_VB1;
                end
                TT_VB1: begin
                    ttb[29] <= 8'h30; ttb[30] <= 8'd16;
                    ttb[31] <= 8'h06; ttb[32] <= 8'd8;
                    ttb[33] <= 8'h2B; ttb[34] <= 8'h06; ttb[35] <= 8'h01;
                    ttb[36] <= 8'h02; ttb[37] <= 8'h01; ttb[38] <= 8'h01;
                    ttb[39] <= 8'h03; ttb[40] <= 8'h00;
                    ttb[41] <= 8'h43; ttb[42] <= 8'd4;
                    ttb[43] <= sys_uptime[31:24]; ttb[44] <= sys_uptime[23:16];
                    ttb[45] <= sys_uptime[15:8];  ttb[46] <= sys_uptime[7:0];
                    tstate  <= TT_VB2;
                end
                TT_VB2: begin
                    ttb[47] <= 8'h30; ttb[48] <= 8'd24;
                    ttb[49] <= 8'h06; ttb[50] <= 8'd10;
                    ttb[51] <= 8'h2B; ttb[52] <= 8'h06; ttb[53] <= 8'h01;
                    ttb[54] <= 8'h06; ttb[55] <= 8'h03; ttb[56] <= 8'h01;
                    ttb[57] <= 8'h01; ttb[58] <= 8'h04; ttb[59] <= 8'h01;
                    ttb[60] <= 8'h00;
                    ttb[61] <= 8'h06; ttb[62] <= 8'd10;
                    ttb[63] <= 8'h2B; ttb[64] <= 8'h06; ttb[65] <= 8'h01;
                    ttb[66] <= 8'h04; ttb[67] <= 8'h01; ttb[68] <= 8'h86;
                    ttb[69] <= 8'h8D; ttb[70] <= 8'h1F; ttb[71] <= 8'h00;
                    ttb[72] <= 8'h01;
                    tstate  <= TT_VB3;
                end
                TT_VB3: begin
                    ttb[73] <= 8'h30; ttb[74] <= 8'd15;
                    ttb[75] <= 8'h06; ttb[76] <= 8'd10;
                    ttb[77] <= 8'h2B; ttb[78] <= 8'h06; ttb[79] <= 8'h01;
                    ttb[80] <= 8'h04; ttb[81] <= 8'h01; ttb[82] <= 8'h86;
                    ttb[83] <= 8'h8D; ttb[84] <= 8'h1F; ttb[85] <= 8'h06;
                    ttb[86] <= 8'h00;
                    ttb[87] <= 8'h02; ttb[88] <= 8'h01; ttb[89] <= vl_fault;
                    tstreaming <= 1'b1;
                    tsp        <= 8'd0;
                    tstate     <= TT_IDLE;
                end
                default: tstate <= TT_IDLE;
                endcase
            end
        end
    end

endmodule
