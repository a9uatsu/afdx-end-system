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


def make_varbind(oid, value_tlv):
    return tlv(0x30, tlv(0x06, oid_bytes(oid)) + value_tlv)


def request_multi(oids, rid, pdu_tag=0xA0, non_rep=0, max_rep=0):
    varbinds = b"".join(make_varbind(oid, tlv(0x05, b"")) for oid in oids)
    pdu_body = (ber_int(rid) + ber_int(non_rep) + ber_int(max_rep) +
                tlv(0x30, varbinds))
    pdu = tlv(pdu_tag, pdu_body)
    return tlv(0x30, tlv(0x02, b"\x01") + tlv(0x04, COMM) + pdu)


def response_multi(varbinds, rid, err_status=0, err_index=0):
    body = b"".join(make_varbind(oid, val) for oid, val in varbinds)
    pdu = tlv(0xA2, ber_int(rid) + ber_int(err_status) + ber_int(err_index) +
                    tlv(0x30, body))
    return tlv(0x30, tlv(0x02, b"\x01") + tlv(0x04, COMM) + pdu)


def next_entry(oid):
    target = oid_bytes(oid)
    for item in MIB:
        if oid_bytes(item[0]) > target:
            return item
    return None

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

    mib_map = {oid: val for oid, _, val in MIB}

    # 7) 多 varbind Get：已知 sysDescr、已知 txFrames、未知 OID
    rid = 0x44440001
    oids = [SYS + ".1.0", ENT + ".1.0", ENT + ".99.0"]
    reqs.append((i, request_multi(oids, rid), 0))
    resps.append((i, response_multi([
        (oids[0], mib_map[oids[0]]),
        (oids[1], mib_map[oids[1]]),
        (oids[2], tlv(0x80, b"")),
    ], rid)))
    i += 1

    # 8) 多 varbind GetNext
    rid = 0x44440002
    oids = [SYS + ".1.0", SYS + ".5.0", ENT + ".7.0"]
    out = []
    for oid in oids:
        nxt = next_entry(oid)
        out.append((oid, tlv(0x82, b"")) if nxt is None else
                   (nxt[0], nxt[2]))
    reqs.append((i, request_multi(oids, rid, 0xA1), 0))
    resps.append((i, response_multi(out, rid)))
    i += 1

    # 9) GetBulk：1 个 non-repeater，1 个 repeater，max-repetitions=2
    rid = 0x55550001
    oids = [SYS + ".1.0", ENT + ".1.0"]
    reqs.append((i, request_multi(oids, rid, 0xA5, 1, 2), 0))
    a = next_entry(oids[0])
    b1 = next_entry(oids[1])
    b2 = next_entry(b1[0]) if b1 else None
    out = [(a[0], a[2]), (b1[0], b1[2]),
           (b2[0], b2[2]) if b2 else (oids[1], tlv(0x82, b""))]
    resps.append((i, response_multi(out, rid)))
    i += 1

    # 10) GetBulk：单 repeater，max-repetitions=3，跨 system/enterprise 子树
    rid = 0x55550002
    oids = [SYS + ".5.0"]
    reqs.append((i, request_multi(oids, rid, 0xA5, 0, 3), 0))
    out = []
    cur = oids[0]
    for _ in range(3):
        nxt = next_entry(cur)
        if nxt is None:
            out.append((cur, tlv(0x82, b"")))
            break
        out.append((nxt[0], nxt[2]))
        cur = nxt[0]
    resps.append((i, response_multi(out, rid)))
    i += 1

    # 11) GetBulk 到达 MIB 末尾：最后一个对象后先返回 endOfMibView，再停止
    rid = 0x55550003
    oids = [ENT + ".6.0"]
    reqs.append((i, request_multi(oids, rid, 0xA5, 0, 3), 0))
    last = next_entry(oids[0])
    resps.append((i, response_multi([
        (last[0], last[2]), (last[0], tlv(0x82, b""))
    ], rid)))
    i += 1

    # 12) GetBulk：两个 repeater，max-repetitions=2，验证行优先顺序
    rid = 0x55550004
    oids = [SYS + ".5.0", ENT + ".5.0"]
    reqs.append((i, request_multi(oids, rid, 0xA5, 0, 2), 0))
    cur = oids[:]
    out = []
    for _ in range(2):
        for j in range(len(oids)):
            nxt = next_entry(cur[j])
            if nxt is None:
                out.append((cur[j], tlv(0x82, b"")))
            else:
                out.append((nxt[0], nxt[2]))
                cur[j] = nxt[0]
    resps.append((i, response_multi(out, rid)))
    i += 1

    # 13) 多 varbind Set：只读 MIB 返回 notWritable，error-index=1
    rid = 0x66660001
    oids = [SYS + ".5.0", ENT + ".1.0"]
    varbinds = (make_varbind(oids[0], tlv(0x04, b"x")) +
                make_varbind(oids[1], tlv(0x41, b"\x00\x00\x00\x01")))
    pdu = tlv(0xA3, ber_int(rid) + ber_int(0) + ber_int(0) +
                     tlv(0x30, varbinds))
    req = tlv(0x30, tlv(0x02, b"\x01") + tlv(0x04, COMM) + pdu)
    reqs.append((i, req, 0))
    resps.append((i, response_multi([
        (oids[0], tlv(0x05, b"")), (oids[1], tlv(0x05, b""))
    ], rid, 5, 1)))
    i += 1

    with open(os.path.join(vdir, "snmp_vectors.txt"), "w", encoding="utf-8") as f:
        for idx, data, exp in reqs:
            f.write(f"F {idx} {len(data)} {exp} " + " ".join(str(b) for b in data) + "\n")

    n_drop = sum(1 for _, _, e in reqs if e == 1)
    n_nosuch = 2
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
