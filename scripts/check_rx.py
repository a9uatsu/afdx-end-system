#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_rx.py - 接收通路结果独立校验

比对 tb_afdx_rx.v 输出的交付记录与 gen_rx_frames.py 生成的期望结果：
  - 交付帧的顺序、VLID、SN、载荷长度与内容
用法: check_rx.py <交付记录文件> <期望文件>
"""
import sys


def read_deliv(path):
    out = []
    counts = None
    for line in open(path, "r", encoding="utf-8"):
        p = line.split()
        if not p:
            continue
        if p[0] == "COUNTS":
            counts = {kv.split("=")[0]: int(kv.split("=")[1]) for kv in p[1:]}
        elif len(p) >= 4 and p[0] == "D":
            vlid = int(p[1])
            sn = int(p[2])
            n = int(p[3])
            pay = bytes(int(x, 16) for x in p[4:4 + n])
            out.append((vlid, sn, n, pay))
    return out, counts


def read_expect(path):
    exp = []
    counts = None
    for line in open(path, "r", encoding="utf-8"):
        p = line.split()
        if not p:
            continue
        if p[0] == "D":
            vlid = int(p[1])
            sn = int(p[2])
            n = int(p[3])
            pay = bytes(int(x) for x in p[4:4 + n])
            exp.append((vlid, sn, n, pay))
        elif p[0] == "COUNTS":
            counts = {kv.split("=")[0]: int(kv.split("=")[1]) for kv in p[1:]}
    return exp, counts


def main():
    if len(sys.argv) < 3:
        print("用法: check_rx.py <deliv.txt> <expect.txt>")
        return 2
    got, rtl_counts = read_deliv(sys.argv[1])
    exp, counts = read_expect(sys.argv[2])

    n_err = 0
    if len(got) != len(exp):
        print(f"[FAIL] 交付帧数 {len(got)} != 期望 {len(exp)}")
        n_err += 1

    for i in range(min(len(got), len(exp))):
        g, e = got[i], exp[i]
        if g[0] != e[0] or g[1] != e[1] or g[2] != e[2]:
            print(f"[FAIL] 第{i}帧 元数据 got=(vlid=0x{g[0]:04x},sn={g[1]},len={g[2]}) "
                  f"exp=(vlid=0x{e[0]:04x},sn={e[1]},len={e[2]})")
            n_err += 1
        elif g[3] != e[3]:
            bad = [k for k in range(len(e[3])) if g[3][k] != e[3][k]]
            print(f"[FAIL] 第{i}帧 载荷不一致（首个不符序号={bad[0] if bad else '-'}）")
            n_err += 1
        else:
            print(f"[PASS] 第{i}帧 vlid=0x{e[0]:04x} sn={e[1]:3d} len={e[2]:4d} 载荷一致")

    # ---- 计数器比对 ----
    if counts and rtl_counts:
        for k in sorted(counts):
            if k not in rtl_counts:
                print(f"[FAIL] RTL 未提供计数器 {k}")
                n_err += 1
            elif rtl_counts[k] != counts[k]:
                print(f"[FAIL] 计数器 {k}: RTL={rtl_counts[k]} 期望={counts[k]}")
                n_err += 1
            else:
                print(f"[PASS] 计数器 {k}: {rtl_counts[k]}")

    print("")
    print("==================== 接收通路校验汇总 ====================")
    print(f"交付帧数      = {len(got)} (期望 {len(exp)})")
    if rtl_counts:
        print(f"RTL 计数器    = {rtl_counts}")
    if counts:
        print(f"期望计数器    = {counts}")
    print(f"错误数        = {n_err}")
    print("RESULT: " + ("PASS" if n_err == 0 else "FAIL"))
    print("=========================================================")
    return 0 if n_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
