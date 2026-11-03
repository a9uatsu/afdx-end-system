#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_snmp.py - 比对 SNMP Agent 响应与 Python 期望"""
import sys


def read(path, tag):
    out, counts = {}, None
    for line in open(path, encoding="utf-8"):
        p = line.split()
        if not p:
            continue
        if p[0] == "COUNTS":
            counts = {kv.split("=")[0]: int(kv.split("=")[1]) for kv in p[1:]}
        elif p[0] == tag:
            n = int(p[2])
            out[int(p[1])] = bytes(int(x) for x in p[3:3 + n])
    return out, counts


def main():
    if len(sys.argv) < 3:
        print("用法: check_snmp.py <resp_dump> <expect>")
        return 2
    got, got_counts = read(sys.argv[1], "R")
    exp, exp_counts = read(sys.argv[2], "R")
    got_t, _ = read(sys.argv[1], "T")
    exp_t, _ = read(sys.argv[2], "T")
    n_err = 0

    for k in sorted(exp):
        if k not in got:
            print(f"[FAIL] 请求 {k} 无响应")
            n_err += 1
        elif got[k] != exp[k]:
            bad = next((i for i in range(min(len(got[k]), len(exp[k])))
                        if got[k][i] != exp[k][i]), None)
            print(f"[FAIL] 请求 {k} 响应不一致 (len {len(got[k])}/{len(exp[k])}, "
                  f"首个差异字节 {bad})")
            print(f"       got={got[k].hex()}")
            print(f"       exp={exp[k].hex()}")
            n_err += 1
        else:
            print(f"[PASS] 请求 {k} 响应一致 ({len(exp[k])} 字节)")

    for k in sorted(got):
        if k not in exp:
            print(f"[FAIL] 请求 {k} 不应有响应")
            n_err += 1

    # ---- Trap 比对 ----
    if exp_t:
        if not got_t:
            print("[FAIL] 未收到 Trap")
            n_err += 1
        for k in sorted(exp_t):
            if got_t.get(k) != exp_t[k]:
                print(f"[FAIL] Trap {k} 不一致 (len {len(got_t.get(k, b''))}/{len(exp_t[k])})")
                n_err += 1
            else:
                print(f"[PASS] Trap {k} 一致 ({len(exp_t[k])} 字节)")

    if got_counts and exp_counts:
        for k in sorted(exp_counts):
            if got_counts.get(k) != exp_counts[k]:
                print(f"[FAIL] 计数器 {k}: RTL={got_counts.get(k)} 期望={exp_counts[k]}")
                n_err += 1
            else:
                print(f"[PASS] 计数器 {k}: {exp_counts[k]}")

    print("")
    print("==================== SNMP Agent 校验汇总 ====================")
    print(f"响应数 {len(got)} / 期望 {len(exp)}   错误数 {n_err}")
    print("RESULT: " + ("PASS" if n_err == 0 else "FAIL"))
    print("=============================================================")
    return 0 if n_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
