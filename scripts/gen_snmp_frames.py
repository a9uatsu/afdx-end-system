#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_snmp_frames.py - 生成"以太网/IP/UDP/SNMP"完整请求帧与期望 SNMP 响应

用于验证 afdx_mgmt_path 的端口 161 分流与 UDP/IP 封装。
输出：
  sim/vectors/snmp_frames.txt      : F <id> <len> <bytes...>
  sim/vectors/snmp_net_expect.txt  : R <id> <len> <payload bytes...> + COUNTS
"""
import binascii
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import gen_snmp_vectors as gv

DST_MAC = bytes.fromhex("020000000101")   # 端系统
SRC_MAC = bytes.fromhex("020000000202")   # 管理站
ES_IP   = bytes([10, 0, 0, 1])
MGMT_IP = bytes([10, 0, 0, 2])
SNMP_PORT = 161
MGMT_PORT = 40000


def cksum16(data):
    if len(data) % 2:
        data += b"\x00"
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) | data[i + 1]
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    chk = (~total) & 0xFFFF
    return 0xFFFF if chk == 0 else chk


def tlv(tag, val):
    assert len(val) < 128
    return bytes([tag, len(val)]) + val


def oid_bytes(text):
    arcs = [int(x) for x in text.split(".")]
    out = bytes([40 * arcs[0] + arcs[1]])
    for a in arcs[2:]:
        if a < 0x80:
            out += bytes([a])
        else:
            tmp = []
            while a:
                tmp.append(a & 0x7F)
                a >>= 7
            tmp.reverse()
            out += bytes([(0x80 | x) if i < len(tmp) - 1 else x
                          for i, x in enumerate(tmp)])
    return out


def ber_int(v):
    b = v.to_bytes(max(1, (v.bit_length() + 7) // 8), "big")
    if b[0] & 0x80:
        b = b"\x00" + b
    return tlv(0x02, b)


def get_request(oid, rid):
    vb = tlv(0x30, tlv(0x06, oid_bytes(oid)) + tlv(0x05, b""))
    pdu = tlv(0xA0, ber_int(rid) + ber_int(0) + ber_int(0) + tlv(0x30, vb))
    return tlv(0x30, tlv(0x02, b"\x01") + tlv(0x04, b"public") + pdu)


def get_response(oid, value, rid):
    vb = tlv(0x30, tlv(0x06, oid_bytes(oid)) + value)
    pdu = tlv(0xA2, ber_int(rid) + ber_int(0) + ber_int(0) + tlv(0x30, vb))
    return tlv(0x30, tlv(0x02, b"\x01") + tlv(0x04, b"public") + pdu)


def eth_frame(payload, sport=MGMT_PORT, dport=SNMP_PORT):
    udp_len = 8 + len(payload)
    ip_tot = 20 + udp_len
    ip = bytearray(20)
    ip[0] = 0x45
    ip[2:4] = ip_tot.to_bytes(2, "big")
    ip[8] = 64
    ip[9] = 17
    ip[12:16] = MGMT_IP
    ip[16:20] = ES_IP
    ip[10:12] = cksum16(bytes(ip)).to_bytes(2, "big")

    udp = bytearray(8)
    udp[0:2] = sport.to_bytes(2, "big")
    udp[2:4] = dport.to_bytes(2, "big")
    udp[4:6] = udp_len.to_bytes(2, "big")
    pseudo = ES_IP + MGMT_IP + bytes([0, 17]) + udp_len.to_bytes(2, "big")
    udp[6:8] = cksum16(pseudo + bytes(udp[0:6]) + b"\x00\x00" + payload).to_bytes(2, "big")

    body = DST_MAC + SRC_MAC + b"\x08\x00" + bytes(ip) + bytes(udp) + payload
    if len(body) < 60:
        body += bytes(60 - len(body))
    fcs = (binascii.crc32(body) & 0xFFFFFFFF).to_bytes(4, "little")
    return body + fcs


SYS = "1.3.6.1.2.1.1"
ENT = "1.3.6.1.4.1.99999"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    vdir = os.path.join(here, "..", "sim", "vectors")
    os.makedirs(vdir, exist_ok=True)

    cases = []
    rid = 0x11110001

    oid = SYS + ".1.0"
    cases.append((oid, get_request(oid, rid), get_response(oid, tlv(0x04, b"AFDX-ES EQ6HL130"), rid)))
    rid += 1

    oid = SYS + ".5.0"
    cases.append((oid, get_request(oid, rid), get_response(oid, tlv(0x04, b"afdx-es"), rid)))
    rid += 1

    oid = ENT + ".99.0"
    cases.append((oid, get_request(oid, rid), get_response(oid, tlv(0x80, b""), rid)))

    # 4) 多 varbind GetRequest：两个已知对象 + 一个未知对象
    rid = 0x77770001
    oids = [SYS + ".1.0", SYS + ".5.0", ENT + ".99.0"]
    mib_map = {oid: val for oid, _, val in gv.MIB}
    multi_get = gv.request_multi(oids, rid)
    multi_get_exp = gv.response_multi([
        (oids[0], mib_map[oids[0]]),
        (oids[1], mib_map[oids[1]]),
        (oids[2], gv.tlv(0x80, b"")),
    ], rid)
    cases.append(("snmp_multi", multi_get, multi_get_exp))

    # 5) GetBulk：sysName 起连续 3 个后继
    rid = 0x77770002
    bulk_oids = [SYS + ".0"]
    bulk_req = gv.request_multi(bulk_oids, rid, 0xA5, 0, 1)
    bulk_out = []
    cur = bulk_oids[0]
    for _ in range(1):
        nxt = gv.next_entry(cur)
        if nxt is None:
            bulk_out.append((cur, gv.tlv(0x82, b"")))
            break
        bulk_out.append((nxt[0], nxt[2]))
        cur = nxt[0]
    cases.append(("snmp_bulk", bulk_req, gv.response_multi(bulk_out, rid)))

    # 6) ARINC 615A 加载器（UDP 10000）：WRQ 请求 -> 8 字节 ACK
    wrq = bytes([0x01, 0x02, 0x64]) + b"afdx.bin"
    cases.append(("load", wrq,
                  bytes([0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])))

    with open(os.path.join(vdir, "snmp_frames.txt"), "w", encoding="utf-8") as f:
        for i, (tag, req, _) in enumerate(cases):
            fr = eth_frame(req, dport=(10000 if tag == "load" else SNMP_PORT))
            f.write(f"F {i} {len(fr)} " + " ".join(str(b) for b in fr) + "\n")

    with open(os.path.join(vdir, "snmp_net_expect.txt"), "w", encoding="utf-8") as f:
        for i, (_, _, exp) in enumerate(cases):
            f.write(f"R {i} {len(exp)} " + " ".join(str(b) for b in exp) + "\n")
        # 计数器只统计 SNMP 引擎（615A 请求不计入 SNMP 计数器）
        n_snmp = sum(1 for tag, _, _ in cases if tag != "load")
        f.write(f"COUNTS req={n_snmp} resp={n_snmp} drop=0 nosuch=2\n")

    print(f"[OK] {len(cases)} SNMP 请求帧")


if __name__ == "__main__":
    main()
