#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_load_vectors.py - 生成 ARINC 615A 风格加载器测试报文与期望响应

输出：
  sim/vectors/load_vectors.txt : F <id> <len> <bytes...>
  sim/vectors/load_expect.txt  : R <id> <len> <bytes...>
"""
import binascii
import os


def resp(op, status=0, arg=0, crc=0):
    return bytes([op | 0x80, status,
                  (arg >> 8) & 0xFF, arg & 0xFF,
                  (crc >> 24) & 0xFF, (crc >> 16) & 0xFF,
                  (crc >> 8) & 0xFF, crc & 0xFF])


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    vdir = os.path.join(here, "..", "sim", "vectors")
    os.makedirs(vdir, exist_ok=True)

    blk1 = bytes((i * 7 + 3) & 0xFF for i in range(512))
    blk2 = bytes((i * 5 + 11) & 0xFF for i in range(100))
    image = blk1 + blk2
    crc = binascii.crc32(image) & 0xFFFFFFFF

    msgs = [
        (bytes([0x01, 0x02, 0x64]) + b"afdx.bin", resp(0x01)),          # WRQ
        (bytes([0x02, 0x00, 0x01]) + blk1, resp(0x02, 0, 1)),           # DATA blk1
        (bytes([0x02, 0x00, 0x02]) + blk2, resp(0x02, 0, 2)),           # DATA blk2
        (bytes([0x03]), resp(0x03, 0, 0, crc)),                         # ACTIVATE
        (bytes([0x04]), resp(0x04, 0, len(image), crc)),                # READ
        (bytes([0x09]), resp(0x09, 2)),                                 # 未知操作码
    ]

    with open(os.path.join(vdir, "load_vectors.txt"), "w", encoding="utf-8") as f:
        for i, (msg, _) in enumerate(msgs):
            f.write(f"F {i} {len(msg)} " + " ".join(str(b) for b in msg) + "\n")

    with open(os.path.join(vdir, "load_expect.txt"), "w", encoding="utf-8") as f:
        for i, (_, r) in enumerate(msgs):
            f.write(f"R {i} {len(r)} " + " ".join(str(b) for b in r) + "\n")

    print(f"[OK] {len(msgs)} 条加载报文，镜像 {len(image)} 字节，CRC=0x{crc:08x}")


if __name__ == "__main__":
    main()
