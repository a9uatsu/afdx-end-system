#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_vectors.py - 生成底层库测试向量（CRC-32 与 16 位反码校验和）

期望值由 Python 独立实现计算，与 Verilog RTL 无共享代码，构成独立比对。
输出格式（每行一个用例）：
    <tag> <nbytes> <64 个字节值，不足补 0> <exp_crc> <exp_ck> <udp_flag>
"""
import binascii
import os
import random


def cksum16(data: bytes, udp_zero_to_ones: int = 0) -> int:
    """16 位反码求和校验和（大端配对，奇数长度补 0x00，进位回卷）"""
    if len(data) % 2:
        data = data + b"\x00"
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) | data[i + 1]
    # 进位回卷折叠
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    chk = (~total) & 0xFFFF
    if chk == 0 and udp_zero_to_ones:
        chk = 0xFFFF
    return chk


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(here, "..", "sim", "vectors")
    os.makedirs(outdir, exist_ok=True)
    out = os.path.join(outdir, "lib_vectors.txt")

    cases = []
    # 1) 定长典型向量
    cases.append(("empty", b""))
    cases.append(("one_byte", b"\x5a"))
    cases.append(("two_bytes", b"\xde\xad"))
    cases.append(("ip_hdr", bytes([
        0x45, 0x00, 0x00, 0x2e, 0x00, 0x00, 0x00, 0x00, 0x01, 0x11,
        0x00, 0x00, 0x0a, 0x00, 0x00, 0x01, 0x0a, 0x00, 0x00, 0x02])))
    cases.append(("udp_hdr", bytes([
        0x0b, 0xb8, 0x0b, 0xb9, 0x00, 0x1c, 0x00, 0x00])))
    cases.append(("all_zero", bytes(20)))
    cases.append(("all_ff", bytes([0xFF] * 21)))
    cases.append(("odd_len", bytes(range(1, 24))))
    cases.append(("max_word", bytes([0xFF] * 40)))
    cases.append(("carry_chain", bytes([0xFF, 0xFF] * 10)))

    # 2) 随机向量（固定种子，保证可复现）
    rnd = random.Random(20261013)
    for n in range(1, 41):
        cases.append((f"rand{n:02d}", bytes(rnd.randrange(256) for _ in range(n))))

    with open(out, "w", encoding="utf-8") as f:
        for tag, data in cases:
            vals = list(data[:64]) + [0] * (64 - min(len(data), 64))
            f.write(f"{tag} {len(data)} " + " ".join(str(x) for x in vals) + " ")
            f.write(f"{crc32(data)} {cksum16(data, 0)} 0\n")
        # 追加 UDP 规则用例（校验和结果落在 0xFFFF 的处理）
        for tag, data in cases[:12]:
            vals = list(data[:64]) + [0] * (64 - min(len(data), 64))
            f.write(f"udp_{tag} {len(data)} " + " ".join(str(x) for x in vals) + " ")
            f.write(f"{crc32(data)} {cksum16(data, 1)} 1\n")

    print(f"[OK] 已生成 {out}  用例数={len(cases) * 2}")


if __name__ == "__main__":
    main()
