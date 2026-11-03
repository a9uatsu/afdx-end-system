#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_rx_frames.py - 生成接收通路测试帧（含错误注入）与期望结果

输出：
  sim/vectors/rx_frames.txt  : 每行一帧  F <id> <len> <expect> <len 个字节值>
                               expect: 0=应接受 1=应拒绝 2=应判重复 3=应接受(失序恢复)
  sim/vectors/rx_expect.txt  : 期望的交付序列与计数器
帧格式与被测 RTL 的约定一致（同一份 Python 参考实现，可独立复核）。
"""
import binascii
import os

CLK_NS = 20
DST_MAC = bytes.fromhex("030000000000")
SRC_MAC = bytes.fromhex("020000000101")


def cksum16(data: bytes, zero_to_ones=False) -> int:
    if len(data) % 2:
        data = data + b"\x00"
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) | data[i + 1]
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    chk = (~total) & 0xFFFF
    if chk == 0 and zero_to_ones:
        chk = 0xFFFF
    return chk


def payload_byte(vlid: int, idx: int, sn: int) -> int:
    return (((vlid & 0xFF) * 37) + ((idx & 0xFF) * 7) +
            (sn * 11) + (((idx >> 8) & 0x7) * 13)) & 0xFF


def build_frame(vlid, sn, dlen, dst_ip, src_ip, dport, sport,
                dst_mac=DST_MAC, src_mac=SRC_MAC, ethertype=0x0800,
                pad_fill=0x00, force_short=False, bad_ipck=False, bad_udpck=False,
                bad_fcs=False, truncate_to=None):
    """按 AFDX 约定构造一帧（字段大端，FCS 小端）"""
    payload = bytes([(vlid >> 8) & 0xFF, vlid & 0xFF, sn]) + \
              bytes(payload_byte(vlid, i, sn) for i in range(dlen))
    udp_len = 8 + len(payload)
    ip_tot = 20 + udp_len

    # IPv4 头
    ip = bytearray(20)
    ip[0] = 0x45
    ip[2] = (ip_tot >> 8) & 0xFF
    ip[3] = ip_tot & 0xFF
    ip[8] = 1                      # TTL
    ip[9] = 17                     # UDP
    ip[12:16] = bytes.fromhex(src_ip)
    ip[16:20] = bytes.fromhex(dst_ip)
    ip[10:12] = cksum16(bytes(ip)).to_bytes(2, "big")
    if bad_ipck:
        ip[10] ^= 0xFF

    # UDP 头
    udp = bytearray(8)
    udp[0:2] = sport.to_bytes(2, "big")
    udp[2:4] = dport.to_bytes(2, "big")
    udp[4:6] = udp_len.to_bytes(2, "big")
    pseudo = ip[12:20] + bytes([0, 17]) + udp_len.to_bytes(2, "big")
    udp[6:8] = cksum16(pseudo + bytes(udp[0:6]) + b"\x00\x00" + payload,
                       zero_to_ones=True).to_bytes(2, "big")
    if bad_udpck:
        udp[6] ^= 0xFF

    body = bytes(dst_mac) + bytes(src_mac) + ethertype.to_bytes(2, "big") + \
           bytes(ip) + bytes(udp) + payload

    # 以太网最小帧填充（不属于 IP 数据报）
    pad_len = 0 if force_short else max(0, 60 - len(body))
    body = body + bytes([pad_fill] * pad_len)

    fcs = (binascii.crc32(body) & 0xFFFFFFFF).to_bytes(4, "little")
    if bad_fcs:
        fcs = bytes([fcs[0] ^ 0xFF]) + fcs[1:]
    frame = body + fcs
    if truncate_to is not None:
        frame = frame[:truncate_to]
    return frame


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    vdir = os.path.join(here, "..", "sim", "vectors")
    os.makedirs(vdir, exist_ok=True)

    # (expect, 帧字节)   expect: 0=接受 1=拒绝 2=重复 3=失序恢复接受
    scen = []

    def f(vlid, sn, dlen, dst_ip, dport, expect, **kw):
        scen.append((expect, build_frame(vlid, sn, dlen, dst_ip, "0a000101", dport, 0x1001, **kw)))

    # ---- VL 0x2001（接收 VL 0）：正常、重复、失序 ----
    f(0x2001, 1, 32, "0a000001", 0x2001, 0)              # 正常
    f(0x2001, 1, 32, "0a000001", 0x2001, 2)              # A/B 另一份副本 -> 重复
    f(0x2001, 2, 32, "0a000001", 0x2001, 0)              # 正常
    f(0x2001, 4, 32, "0a000001", 0x2001, 3)              # 跳过 SN=3 -> 前向恢复
    f(0x2001, 4, 32, "0a000001", 0x2001, 2)              # 重复
    f(0x2001, 3, 32, "0a000001", 0x2001, 2)              # 过期帧 -> 丢弃

    # ---- VL 0x2002（接收 VL 1）：零长度载荷 / 最大载荷 ----
    f(0x2002, 1, 0, "0a000002", 0x2002, 0)               # 零长度载荷（最小帧 64）
    f(0x2002, 2, 1468, "0a000002", 0x2002, 0)            # 最大载荷（帧长 1517）

    # ---- 未配置的 VL ----
    f(0x2099, 1, 32, "0a000099", 0x2099, 1)              # 未知 VLID -> 拒绝

    # ---- 各类校验错误 ----
    f(0x2001, 5, 32, "0a000001", 0x2001, 1, bad_fcs=True)     # FCS 错
    f(0x2001, 5, 32, "0a000001", 0x2001, 0)                   # 错误帧不应消耗 SN
    f(0x2001, 6, 32, "0a000001", 0x2001, 1,
      dst_mac=bytes.fromhex("0300000000ff"))                   # 目的 MAC 错
    f(0x2001, 6, 32, "0a000001", 0x2001, 1, ethertype=0x0806)  # EtherType 错
    f(0x2001, 6, 32, "0a000001", 0x2001, 1, bad_ipck=True)     # IPv4 校验和错
    f(0x2001, 6, 32, "0a000001", 0x2001, 1, bad_udpck=True)    # UDP 校验和错
    f(0x2001, 6, 32, "0a000001", 0x2001, 1, truncate_to=50)    # 帧长不足 64
    f(0x2001, 6, 0,  "0a000001", 0x2001, 1, pad_fill=0xA5)     # 填充字节非 0
    f(0x2001, 6, 32, "0a000001", 0x2001, 0)                    # 恢复：正常帧

    # ---- 触发完整性检查：0x2002 连续 3 次失序 ----
    f(0x2002, 6, 8, "0a000002", 0x2002, 3)
    f(0x2002, 12, 8, "0a000002", 0x2002, 3)
    f(0x2002, 18, 8, "0a000002", 0x2002, 3)

    # ---------------- 写帧文件 ----------------
    fpath = os.path.join(vdir, "rx_frames.txt")
    with open(fpath, "w", encoding="utf-8") as fh:
        for i, (exp, data) in enumerate(scen):
            vals = " ".join(str(b) for b in data)
            fh.write(f"F {i} {len(data)} {exp} {vals}\n")

    # ---------------- 写期望结果 ----------------
    epath = os.path.join(vdir, "rx_expect.txt")
    n_acc = n_rej = n_dup = 0
    with open(epath, "w", encoding="utf-8") as fh:
        for exp, data in scen:
            if exp in (0, 3):
                vlid = (data[42] << 8) | data[43]
                sn = data[44]
                ulen = (data[38] << 8) | data[39]
                dlen = ulen - 11
                pay = data[45:45 + dlen]
                fh.write(f"D {vlid} {sn} {dlen} " + " ".join(str(b) for b in pay) + "\n")
                n_acc += 1
            elif exp == 2:
                n_dup += 1
            else:
                n_rej += 1
        n_oos = sum(1 for e, _ in scen if e == 3)        # 失序但接受（恢复）次数
        n_unknown = 1
        n_err = n_rej - n_unknown                        # 未知 VL 由冗余管理计数
        n_ic = n_oos + 1                                 # 4 次恢复 + 1 次过期帧
        fh.write(f"COUNTS accept={n_acc} dup={n_dup} oos={n_oos} "
                 f"unknown={n_unknown} err={n_err} ic={n_ic} fault=2\n")

    print(f"[OK] 生成 {fpath}  共 {len(scen)} 帧")
    print(f"[OK] 生成 {epath}")


if __name__ == "__main__":
    main()
