#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""128 VL 长时压测独立校验与统计汇总。

复用 check_frames.py 的独立协议参考模型检查每个字段，并为本用例生成
逐 VL 的 min/avg/max 起始间隔、标准差和最大抖动表。
"""
import io
import os
import sys
from collections import Counter
from contextlib import redirect_stdout
from math import sqrt

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import check_frames as cf


def configure_reference():
    cf.BAG_CYCLES = {}
    cf.VLS = {}
    for i in range(128):
        vlid = 0x3000 + i
        cf.BAG_CYCLES[vlid] = (50000, 100000, 200000)[i % 3]
        dlen = (0, 16, 32, 64)[i % 4]
        cf.VLS[vlid] = (
            dlen,
            "030000000000",
            "020000000101",
            f"0a0000{i + 1:02x}",
            "0a000101",
            0x3000 + i,
            0x1001,
        )


def main():
    if len(sys.argv) not in (3, 4):
        print("usage: check_soak.py <buslog> <soak_expect.txt> [min_frames]")
        return 2
    buslog, out_path = sys.argv[1:3]
    min_required = int(sys.argv[3]) if len(sys.argv) == 4 else 20

    configure_reference()
    frames = cf.parse_buslog(buslog)
    counts = Counter()
    last_start = {}
    intervals = {0x3000 + i: [] for i in range(128)}
    for frame, t_start in frames:
        if len(frame) < 44:
            continue
        vlid = (frame[42] << 8) | frame[43]
        counts[vlid] += 1
        if vlid in last_start:
            intervals.setdefault(vlid, []).append(t_start - last_start[vlid])
        last_start[vlid] = t_start

    # 复用完整字段/校验和/FCS/SN/BAG 参考检查，捕获其逐 VL 输出。
    captured = io.StringIO()
    old_argv = sys.argv[:]
    try:
        sys.argv = [old_argv[0], buslog]
        with redirect_stdout(captured):
            protocol_rc = cf.main()
    finally:
        sys.argv = old_argv
    protocol_log = captured.getvalue()

    rows = []
    bag_fail = []
    starvation = []
    no_sample = []
    max_jitter_ns = 0
    worst_margin_ns = 10 ** 18
    for i in range(128):
        vlid = 0x3000 + i
        bag_ns = cf.BAG_CYCLES[vlid] * cf.CLK_NS
        samples = intervals.get(vlid, [])
        if not samples:
            no_sample.append(vlid)
            rows.append((i, vlid, bag_ns, counts[vlid], 0, 0.0, 0, 0.0, 0, "NO_SAMPLE"))
            continue
        avg = sum(samples) / len(samples)
        variance = sum((x - avg) ** 2 for x in samples) / len(samples)
        sd = sqrt(variance)
        imin, imax = min(samples), max(samples)
        jitters = [x - bag_ns for x in samples]
        max_jitter = max(jitters)
        max_jitter_ns = max(max_jitter_ns, max_jitter)
        worst_margin_ns = min(worst_margin_ns, imin - bag_ns)
        if imin < bag_ns:
            bag_fail.append(vlid)
        if counts[vlid] < min_required:
            starvation.append(vlid)
        status = "PASS"
        if imin < bag_ns or counts[vlid] < min_required:
            status = "FAIL"
        rows.append((i, vlid, bag_ns, counts[vlid], imin, avg, imax, sd,
                     max_jitter, status))

    overall = protocol_rc == 0 and not bag_fail and not starvation and not no_sample
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("# AFDX 128 VL long soak summary\n")
        f.write(f"buslog={os.path.basename(buslog)}\n")
        f.write(f"frames={len(frames)}\n")
        f.write(f"vl_count=128\n")
        f.write(f"min_required_frames_per_vl={min_required}\n")
        f.write("columns=vl_index,vlid,bag_ns,frames,interval_min_ns,interval_avg_ns,interval_max_ns,interval_std_ns,max_jitter_ns,status\n")
        for row in rows:
            f.write("%d,0x%04x,%d,%d,%d,%.1f,%d,%.1f,%d,%s\n" % row)
        f.write(f"bag_violations={len(bag_fail)}\n")
        f.write(f"starvation_vl={len(starvation)}\n")
        f.write(f"no_sample_vl={len(no_sample)}\n")
        f.write(f"worst_bag_margin_ns={worst_margin_ns if worst_margin_ns != 10**18 else 0}\n")
        f.write(f"max_jitter_ns={max_jitter_ns}\n")
        f.write(f"protocol_check={'PASS' if protocol_rc == 0 else 'FAIL'}\n")
        f.write(f"overall={'PASS' if overall else 'FAIL'}\n")
        f.write("protocol_reference_summary_begin\n")
        for line in protocol_log.splitlines():
            if ("解析帧数" in line or "帧长范围" in line or "错误数" in line
                    or "RESULT:" in line):
                f.write(line + "\n")
        f.write("protocol_reference_summary_end\n")

    min_count = min(counts.values()) if counts else 0
    print(f"[INFO] soak frames={len(frames)} min_vl_frames={min_count} "
          f"worst_bag_margin_ns={worst_margin_ns if worst_margin_ns != 10**18 else 0}")
    print(f"[INFO] max_jitter_ns={max_jitter_ns} bag_violations={len(bag_fail)} "
          f"starvation_vl={len(starvation)}")
    if bag_fail:
        print("[FAIL] BAG violations: " + " ".join(f"0x{x:04x}" for x in bag_fail[:16]))
    if starvation:
        print("[FAIL] starved VL: " + " ".join(f"0x{x:04x}" for x in starvation[:16]))
    print(f"[INFO] summary table={out_path}")
    print("RESULT: " + ("PASS (128 VL SOAK)" if overall else "FAIL"))
    return 0 if overall else 1


if __name__ == "__main__":
    raise SystemExit(main())
