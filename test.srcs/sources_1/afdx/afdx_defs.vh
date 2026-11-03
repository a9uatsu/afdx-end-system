// =============================================================================
// 文件名  : afdx_defs.vh
// 模块    : 全局参数与常量定义（被各 RTL 文件 include）
// 赛题    : 全国大学生嵌入式芯片与系统设计竞赛'2026 FPGA 创新设计赛道
//           选题一 基于以太网 MAC 总线实现 AFDX（ARINC 664 Part 7 端系统）
// 说明    : 端口/信号/寄存器一律小写，参数一律大写（赛题代码规范）
// =============================================================================

`ifndef AFDX_DEFS_VH
`define AFDX_DEFS_VH

// ---------------------------------------------------------------------------
// 一、以太网与协议常量（IEEE 802.3 / ARINC 664 Part 7 / RFC 791 / RFC 768）
// ---------------------------------------------------------------------------
`define ETH_HDR_BYTES       6'd14      // 目的MAC(6) + 源MAC(6) + 类型(2)
`define ETH_TYPE_IPV4       16'h0800   // 以太网类型：IPv4
`define ETH_TYPE_IPV4_HI    8'h08      // 同上，字节粒度（宏不可带位选）
`define ETH_TYPE_IPV4_LO    8'h00
`define ETH_MAC_BYTES       6
`define ETH_MIN_FRAME       16'd64     // 以太网最小帧长（不含前导码，含FCS）
`define ETH_MAX_FRAME       16'd1518   // 以太网最大帧长（含FCS）

`define IPV4_HDR_BYTES      6'd20      // IPv4 固定头长
`define IPV4_VERSION_IHL    8'h45      // 版本4 + 头长5(32位字)
`define IPV4_TOS            8'h00
`define IPV4_PROTO_UDP      8'h11      // 协议号：UDP
`define IPV4_ID             16'h0000   // AFDX 不使用分片，标识固定 0
`define IPV4_ID_HI          8'h00
`define IPV4_ID_LO          8'h00
`define IPV4_FLAGS_FRAG     16'h0000
`define IPV4_FLAGS_FRAG_HI  8'h00
`define IPV4_FLAGS_FRAG_LO  8'h00
`define IPV4_TTL            8'h01      // AFDX 特性：TTL = 1

`define UDP_HDR_BYTES       6'd8       // 源端口(2) + 目的端口(2) + 长度(2) + 校验和(2)

`define FCS_BYTES           6'd4       // 以太网帧校验序列（CRC-32）

// AFDX 载荷头部：显式携带 VLID 与序列号，便于逐字段核对。
//   载荷布局 = [ vlid(2B) ][ sn(1B) ][ 功能数据 ]
// 参数选择说明：标准中 VL 由 IP/UDP 寻址隐式确定、SN 位于载荷末字节；
//   本设计把两者显式放在载荷头部（可通过 PAYLOAD_HDR_MODE 切换），
//   便于评测与调试，且不影响协议解析流程。
`define PAYLOAD_HDR_BYTES   6'd3       // vlid(2) + sn(1)
`define AFDX_VLID_BYTES     6'd2
`define AFDX_SN_BYTES       6'd1

// 序列号规则：1..255 循环，0 为复位/重新开始语义
`define SN_MIN              8'd1
`define SN_MAX              8'd255
`define SN_RESET            8'd0

// ---------------------------------------------------------------------------
// 二、AFDX 指标常量（赛题给定）
// ---------------------------------------------------------------------------
`define AFDX_LINE_RATE_MBPS 16'd100            // 传输速率 100 Mbps
`define AFDX_LMAX_BYTES     11'd1471           // 最大有效载荷（含 VLID 2B + SN 1B）
`define AFDX_LMAX_DATA      11'd1468           // 最大功能数据（1471 - 3）
`define AFDX_MAX_FRAME      16'd1518           // 总帧长上限（含 FCS）

// ---------------------------------------------------------------------------
// 三、功能数据生成（发送与验证必须一致；Python 参考模型按同一公式复现）
//     byte = (vlid_lo*37 + idx_lo*7 + sn*11 + idx_hi3*13) mod 256
//     vlid_lo: VLID 低 8 位, idx_lo: 数据序号低 8 位,
//     idx_hi3: 数据序号高 3 位 (idx[10:8]), sn: 序列号
// ---------------------------------------------------------------------------
`define AFDX_PAYLOAD_BYTE(vlid, idx, sn) \
    ((vlid[7:0] * 8'd37) + (idx[7:0] * 8'd7) + (sn * 8'd11) + (idx[10:8] * 8'd13))

// ---------------------------------------------------------------------------
// 四、MAC 总线（8 位）成帧约定
//     - 一个帧 = 握手上连续出现的字节序列
//     - 帧间必须插入至少 1 个时钟的空闲（无握手），空闲即帧边界
//     - 帧内不得出现空闲（背压时保持 valid 不撤销）
//     顶层仅给出 tx_data/tx_valid/tx_ready 与 rx_data/rx_valid/rx_ready，
//     没有独立的 sop/eop 信号，因此采用上述空闲定界约定（详见设计文档）。
// ---------------------------------------------------------------------------

// 冗余网口标识
`define NET_A               1'b0
`define NET_B               1'b1

`endif // AFDX_DEFS_VH
