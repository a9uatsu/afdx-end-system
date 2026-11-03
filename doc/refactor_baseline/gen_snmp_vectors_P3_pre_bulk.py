#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_snmp_vectors.py - 生成 SNMP v2c GetRequest 测试报文与期望响应

输出：
  sim/vectors/snmp_vectors.txt : F <id> <len> <expect> <bytes...>
                                 expect 0=应有响应 1=应静默丢弃
  sim/vectors/snmp_expect.txt  : R <id> <len> <bytes...> + COUNTS 行

BER 编码由本脚本独立实现，与 RTL 无共享代码。
"""
import os

COMM = b"public"
SYS = "1.3.6.1.2.1.1"
ENT = "1.3.6.1.4.1.99999"


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


def tlv(tag, val):
    assert len(val) < 128, f"length {len(val)} too long for short form"
    return bytes([tag, len(val)]) + val


def ber_int(v):
    b = v.to_bytes(max(1, (v.bit_length() + 7) // 8), "big")
    if b[0] & 0x80:
        b = b"\x00" + b
    return tlv(0x02, b)


def get_request(oid, rid=0x12345678, ver=1, comm=COMM):
    varbind = tlv(0x30, tlv(0x06, oid_bytes(oid)) + tlv(0x05, b""))
    vb_list = tlv(0x30, varbind)
    pdu_body = ber_int(rid) + ber_int(0) + ber_int(0) + vb_list
    pdu = tlv(0xA0, pdu_body)
    return tlv(0x30, tlv(0x02, bytes([ver])) + tlv(0x04, comm) + pdu)


def get_next_request(oid, rid=0x12345678, ver=1, comm=COMM):
    varbind = tlv(0x30, tlv(0x06, oid_bytes(oid)) + tlv(0x05, b""))
    vb_list = tlv(0x30, varbind)
    pdu_body = ber_int(rid) + ber_int(0) + ber_int(0) + vb_list
    pdu = tlv(0xA1, pdu_body)
    return tlv(0x30, tlv(0x02, bytes([ver])) + tlv(0x04, comm) + pdu)


def set_request(oid, value, rid=0x12345678, ver=1, comm=COMM):
    varbind = tlv(0x30, tlv(0x06, oid_bytes(oid)) + value)
    vb_list = tlv(0x30, varbind)
    pdu_body = ber_int(rid) + ber_int(0) + ber_int(0) + vb_list
    pdu = tlv(0xA3, pdu_body)
    return tlv(0x30, tlv(0x02, bytes([ver])) + tlv(0x04, comm) + pdu)


def set_response(oid, rid=0x12345678, ver=1):
    """只读 MIB：GetResponse + notWritable(5), error-index=1, varbind 回显 NULL"""
    varbind = tlv(0x30, tlv(0x06, oid_bytes(oid)) + tlv(0x05, b""))
    pdu = tlv(0xA2, ber_int(rid) + ber_int(5) + ber_int(1) + tlv(0x30, varbind))
    return tlv(0x30, tlv(0x02, bytes([ver])) + tlv(0x04, COMM) + pdu)


def get_response(oid, value_tlv, rid=0x12345678, ver=1):
    varbind = tlv(0x30, tlv(0x06, oid_bytes(oid)) + value_tlv)
    vb_list = tlv(0x30, varbind)
    pdu_body = ber_int(rid) + ber_int(0) + ber_int(0) + vb_list
    pdu = tlv(0xA2, pdu_body)
    return tlv(0x30, tlv(0x02, bytes([ver])) + tlv(0x04, COMM) + pdu)


MIB = [
    (SYS + ".1.0", "descr",   tlv(0x04, b"AFDX-ES EQ6HL130")),
    (SYS + ".3.0", "uptime",  tlv(0x43, (0x1234).to_bytes(4, "big"))),
    (SYS + ".5.0", "name",    tlv(0x04, b"afdx-es")),
    (ENT + ".1.0", "txfrm",   tlv(0x41, (42).to_bytes(4, "big"))),
    (ENT + ".2.0", "rxfrm",   tlv(0x41, (256).to_bytes(4, "big"))),
    (ENT + ".3.0", "rxerr",   tlv(0x41, (3).to_bytes(4, "big"))),
    (ENT + ".4.0", "dup",     tlv(0x41, (5).to_bytes(4, "big"))),
    (ENT + ".5.0", "icerr",   tlv(0x41, (7).to_bytes(4, "big"))),
    (ENT + ".6.0", "vlfault", tlv(0x02, bytes([5]))),
    (ENT + ".7.0", "vlcap",   tlv(0x02, (4096).to_bytes(2, "big"))),
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    vdir = os.path.join(here, "..", "sim", "vectors")
    os.makedirs(vdir, exist_ok=True)

    reqs = []      # (id, bytes, expect)
    resps = []     # (id, bytes)
    rid = 0x12345678
    i = 0

    # 1) 10 个正常对象
    for oid, tag, val in MIB:
        req = get_request(oid, rid)
        exp = get_response(oid, val, rid)
        reqs.append((i, req, 0))
        resps.append((i, exp))
        i += 1
        rid = (rid + 1) & 0xFFFFFFFF

    # 2) 未知 OID -> noSuchObject
    unknown_oid = ENT + ".99.0"
    reqs.append((i, get_request(unknown_oid, rid), 0))
    resps.append((i, get_response(unknown_oid, tlv(0x80, b""), rid)))
    i += 1
    rid = (rid + 1) & 0xFFFFFFFF

    # 3) 错误社区 -> 丢弃
    reqs.append((i, get_request(SYS + ".1.0", rid, comm=b"private"), 1))
    i += 1

    # 4) GetNext：sysDescr -> sysUpTime，sysName -> ent.1.0，最后一个 -> endOfMibView
    rid = 0x22220001
    reqs.append((i, get_next_request(SYS + ".1.0", rid), 0))
    resps.append((i, get_response(SYS + ".3.0", tlv(0x43, (0x1234).to_bytes(4, "big")), rid)))
    i += 1; rid += 1
    reqs.append((i, get_next_request(SYS + ".5.0", rid), 0))
    resps.append((i, get_response(ENT + ".1.0", tlv(0x41, (42).to_bytes(4, "big")), rid)))
    i += 1; rid += 1
    reqs.append((i, get_next_request(ENT + ".7.0", rid), 0))
    resps.append((i, get_response(ENT + ".7.0", tlv(0x82, b""), rid)))
    i += 1

    # 5) 请求-id 变化（验证原样回显）
    rid = 0xA1B2C3D4
    reqs.append((i, get_request(ENT + ".2.0", rid), 0))
    resps.append((i, get_response(ENT + ".2.0", tlv(0x41, (256).to_bytes(4, "big")), rid)))
    i += 1

    # 6) SetRequest：只读 MIB -> notWritable
    rid = 0x33330001
    reqs.append((i, set_request(SYS + ".5.0", tlv(0x04, b"x"), rid), 0))
    resps.append((i, set_response(SYS + ".5.0", rid)))
    i += 1

    with open(os.path.join(vdir, "snmp_vectors.txt"), "w", encoding="utf-8") as f:
        for idx, data, exp in reqs:
            f.write(f"F {idx} {len(data)} {exp} " + " ".join(str(b) for b in data) + "\n")

    n_drop = sum(1 for _, _, e in reqs if e == 1)
    n_nosuch = 1
    with open(os.path.join(vdir, "snmp_expect.txt"), "w", encoding="utf-8") as f:
        for idx, data in resps:
            f.write(f"R {idx} {len(data)} " + " ".join(str(b) for b in data) + "\n")
        # v2c Trap-PDU：sysUpTime.0 + snmpTrapOID.0 + afdxVlFault.0
        trap = tlv(0x30,
                   tlv(0x02, b"\x01") + tlv(0x04, COMM) +
                   tlv(0xA7,
                       tlv(0x02, (1).to_bytes(4, "big")) +
                       tlv(0x02, b"\x00") + tlv(0x02, b"\x00") +
                       tlv(0x30,
                           tlv(0x30, tlv(0x06, oid_bytes(SYS + ".3.0")) +
                                      tlv(0x43, (0x1234).to_bytes(4, "big"))) +
                           tlv(0x30, tlv(0x06, oid_bytes("1.3.6.1.6.3.1.1.4.1.0")) +
                                      tlv(0x06, oid_bytes(ENT + ".0.1"))) +
                           tlv(0x30, tlv(0x06, oid_bytes(ENT + ".6.0")) +
                                      tlv(0x02, b"\x07")))))
        assert len(trap) == 90, len(trap)
        f.write(f"T 0 {len(trap)} " + " ".join(str(b) for b in trap) + "\n")
        f.write(f"COUNTS req={len(reqs)} resp={len(resps)} drop={n_drop} "
                f"nosuch={n_nosuch}\n")

    print(f"[OK] {len(reqs)} requests, {len(resps)} responses, {n_drop} drop")


if __name__ == "__main__":
    main()
