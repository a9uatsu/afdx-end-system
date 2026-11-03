#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_frames.py - AFDX 发送帧独立校验（Python 参考模型）

输入：tb_afdx_tx.v 输出的 MAC 总线逐周期记录（B/S/I 标记）
检查：分帧、帧长、MAC/以太网类型、IPv4 头与校验和、UDP 头与校验和、
      载荷生成公式、FCS(CRC-32)、填充字节、序列号递增与回绕、BAG 起始间隔

本脚本与被测 RTL 无任何共享实现，构成独立比对。
"""
import binascii
import re
import sys

# ---------------------------------------------------------------------------
# 期望配置（必须与 tb_afdx_tx.v 中的 cfg_* 调用一致）
# ---------------------------------------------------------------------------
CLK_NS = 20
BAG_CYCLES = {0x1001: 2000, 0x1002: 12000, 0x1003: 6000}
VLS = {
    # vlid : (data_len, dst_mac, src_mac, dst_ip, src_ip, dst_port, src_port)
    0x1001: (32,   "030000000000", "020000000101",
             "0a000001", "0a000101", 0x2001, 0x1001),
    0x1002: (1468, "030000000000", "020000000101",
             "0a000002", "0a000101", 0x2002, 0x1001),
    0x1003: (0,    "030000000000", "020000000101",
             "0a000003", "0a000101", 0x2003, 0x1001),
}


def cksum16(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) | data[i + 1]
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    chk = (~total) & 0xFFFF
    return 0xFFFF if chk == 0 else chk


def payload_byte(vlid: int, idx: int, sn: int) -> int:
    """与 afdx_defs.vh 中 AFDX_PAYLOAD_BYTE 宏一致的公式"""
    return (((vlid & 0xFF) * 37) + ((idx & 0xFF) * 7) +
            (sn * 11) + (((idx >> 8) & 0x7) * 13)) & 0xFF


def parse_buslog(path):
    """返回 [(frame_bytes, t_start_ns), ...]"""
    frames = []
    cur = []
    t_start = None
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            tag = parts[0]
            if tag == "B":
                t = int(parts[1])
                b = int(parts[2], 16)
                if not cur:
                    t_start = t
                cur.append(b)
            elif tag == "I":
                if cur:
                    frames.append((bytes(cur), t_start))
                    cur = []
            # S（背压停顿）不打断帧，忽略
    if cur:
        frames.append((bytes(cur), t_start))
    return frames


def main():
    if len(sys.argv) < 2:
        print("用法: check_frames.py <buslog.txt>")
        return 2
    path = sys.argv[1]
    frames = parse_buslog(path)

    n_err = 0
    n_pass = 0
    last_t = {}
    expect_sn = {}
    min_iv = {}
    n_vl = {}
    ivs = {}          # 每个 VL 的起始间隔样本（ns）
    lens = []

    def err(fi, msg):
        nonlocal n_err
        n_err += 1
        print(f"[FAIL] 帧{fi}: {msg}")

    for fi, (f, t0) in enumerate(frames):
        L = len(f)
        lens.append(L)

        # ---- 帧长 ----
        if L < 64 or L > 1518:
            err(fi, f"帧长 {L} 越界 (要求 64..1518)")
            continue

        # ---- 以太网头 ----
        dst_mac = f[0:6].hex()
        src_mac = f[6:12].hex()
        etype = (f[12] << 8) | f[13]
        if etype != 0x0800:
            err(fi, f"EtherType=0x{etype:04x} != 0x0800")

        # ---- IPv4 头 ----
        ip = f[14:34]
        ver_ihl = ip[0]
        tot_len = (ip[2] << 8) | ip[3]
        ttl = ip[8]
        proto = ip[9]
        ip_ck = (ip[10] << 8) | ip[11]
        if ver_ihl != 0x45:
            err(fi, f"IPv4 版本/头长 0x{ver_ihl:02x} != 0x45")
        if proto != 17:
            err(fi, f"协议号 {proto} != 17(UDP)")
        if ttl != 1:
            err(fi, f"TTL {ttl} != 1 (AFDX)")
        if tot_len > L - 18:
            err(fi, f"IPv4 总长 {tot_len} 超出帧容量 {L-18}")
        ip_hdr_zero = ip[:10] + b"\x00\x00" + ip[12:]
        if cksum16(ip_hdr_zero) != ip_ck:
            err(fi, f"IPv4 头校验和 0x{ip_ck:04x} != 0x{cksum16(ip_hdr_zero):04x}")
        src_ip = ip[12:16].hex()
        dst_ip = ip[16:20].hex()

        # ---- UDP 头 ----
        udp = f[34:42]
        sport = (udp[0] << 8) | udp[1]
        dport = (udp[2] << 8) | udp[3]
        ulen = (udp[4] << 8) | udp[5]
        uck = (udp[6] << 8) | udp[7]

        # ---- 载荷（VLID 2B + SN 1B + 功能数据），填充 0x00 ----
        # 注：以太网填充字节不属于 IP 数据报，IPv4 总长不包含填充，
        #     因此载荷长度以 UDP 长度字段为准。
        pay_total = ulen - 8
        if ulen != tot_len - 20:
            err(fi, f"UDP 长度 {ulen} != IP 总长-20 = {tot_len-20}")
        pad = L - 4 - (14 + tot_len)
        payload = f[42:42 + pay_total]
        padding = f[42 + pay_total:L - 4]
        if len(padding) != pad or (pad > 0 and any(padding)):
            err(fi, f"填充字节非全 0 (pad={pad}, 实际={padding.hex()})")
        vlid = (payload[0] << 8) | payload[1]
        sn = payload[2]
        data = payload[3:]

        # ---- FCS ----
        fcs_rx = int.from_bytes(f[L - 4:L], "little")
        fcs_calc = binascii.crc32(f[:L - 4]) & 0xFFFFFFFF
        if fcs_rx != fcs_calc:
            err(fi, f"FCS 0x{fcs_rx:08x} != 0x{fcs_calc:08x}")

        if vlid not in VLS:
            err(fi, f"未知 VLID 0x{vlid:04x}")
            continue
        dlen, e_dmac, e_smac, e_dip, e_sip, e_dport, e_sport = VLS[vlid]
        n_vl[vlid] = n_vl.get(vlid, 0) + 1

        # ---- 字段比对 ----
        if dst_mac != e_dmac:
            err(fi, f"目的 MAC {dst_mac} != {e_dmac}")
        if src_mac != e_smac:
            err(fi, f"源 MAC {src_mac} != {e_smac}")
        if dst_ip != e_dip:
            err(fi, f"目的 IP {dst_ip} != {e_dip}")
        if src_ip != e_sip:
            err(fi, f"源 IP {src_ip} != {e_sip}")
        if dport != e_dport:
            err(fi, f"目的端口 0x{dport:04x} != 0x{e_dport:04x}")
        if sport != e_sport:
            err(fi, f"源端口 0x{sport:04x} != 0x{e_sport:04x}")
        if ulen != 8 + pay_total:
            err(fi, f"UDP 长度 {ulen} != 8+{pay_total}")
        if len(data) != dlen:
            err(fi, f"功能数据长度 {len(data)} != 配置 {dlen}")

        # ---- UDP 校验和（含伪首部）----
        # UDP 伪首部：源IP(4) 目的IP(4) 0x00 协议(1) UDP长度(2)
        pseudo = ip[12:20] + bytes([0, 17]) + (8 + pay_total).to_bytes(2, "big")
        udp_for_ck = udp[:6] + b"\x00\x00" + payload
        if cksum16(pseudo + udp_for_ck) != uck:
            err(fi, f"UDP 校验和 0x{uck:04x} != 0x{cksum16(pseudo+udp_for_ck):04x}")

        # ---- 载荷内容（生成公式）----
        bad = [i for i in range(len(data)) if data[i] != payload_byte(vlid, i, sn)]
        if bad:
            err(fi, f"功能数据与生成公式不符 (首个不符序号={bad[0]})")

        # ---- 序列号 ----
        exp = expect_sn.get(vlid, 1)
        if sn != exp:
            err(fi, f"SN={sn} != 期望 {exp}")
        expect_sn[vlid] = 1 if sn == 255 else sn + 1

        # ---- BAG 起始间隔 ----
        if vlid in last_t:
            iv = t0 - last_t[vlid]
            bag_ns = BAG_CYCLES[vlid] * CLK_NS
            min_iv[vlid] = min(min_iv.get(vlid, 10 ** 12), iv)
            ivs.setdefault(vlid, []).append(iv)
            if iv < bag_ns:
                err(fi, f"VL 0x{vlid:04x} 起始间隔 {iv}ns < BAG {bag_ns}ns")
        last_t[vlid] = t0

        n_pass += 1

    # ------------------------------------------------------------------
    print("")
    print("==================== 发送帧独立校验汇总 ====================")
    print(f"解析帧数        = {len(frames)}")
    print(f"帧长范围        = {min(lens) if lens else 0} .. {max(lens) if lens else 0} 字节")
    for vlid in sorted(n_vl):
        bag_ns = BAG_CYCLES[vlid] * CLK_NS
        s = ivs.get(vlid, [])
        if s:
            avg = sum(s) / len(s)
            var = sum((x - avg) ** 2 for x in s) / len(s)
            sd = var ** 0.5
            jit = [x - bag_ns for x in s]
            print(f"VLID 0x{vlid:04x}: 帧数={n_vl[vlid]:2d} BAG={bag_ns:7d}ns "
                  f"间隔 min/avg/max={min(s):7d}/{avg:9.1f}/{max(s):7d}ns "
                  f"抖动(间隔-BAG) min/avg/max={min(jit):6d}/{sum(jit)/len(jit):8.1f}/{max(jit):6d}ns "
                  f"标准差={sd:8.1f}ns")
        else:
            print(f"VLID 0x{vlid:04x}: 帧数={n_vl[vlid]:2d} BAG={bag_ns:7d}ns (样本不足)")
    print(f"错误数          = {n_err}")
    print("RESULT: " + ("PASS" if n_err == 0 and len(frames) > 0 else "FAIL"))
    print("===========================================================")
    return 0 if n_err == 0 and len(frames) > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
