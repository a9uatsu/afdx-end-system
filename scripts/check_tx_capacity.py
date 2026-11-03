#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""S2 32 VL 独立检查：复用 check_frames.py 的协议参考模型并检查饿死。"""
import os
import sys
from collections import Counter

def load_reference():
    scripts = os.path.dirname(os.path.abspath(__file__))
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    import check_frames
    return check_frames


def configure_reference(cf):
    cf.BAG_CYCLES = {}
    cf.VLS = {}
    for i in range(32):
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
    if len(sys.argv) != 2:
        print("usage: check_tx_capacity.py <buslog>")
        return 2
    cf = load_reference()
    configure_reference(cf)
    frames = cf.parse_buslog(sys.argv[1])
    counts = Counter()
    for f, _ in frames:
        if len(f) >= 44:
            vlid = (f[42] << 8) | f[43]
            counts[vlid] += 1
    missing = [0x3000 + i for i in range(32) if counts[0x3000 + i] < 3]
    print(f"[INFO] 32 VL 最少发送帧数={min(counts.values()) if counts else 0}")
    if missing:
        print("[FAIL] 以下 VL 少于 3 帧: " +
              " ".join(f"0x{x:04x}" for x in missing))
        rc = 1
    else:
        rc = 0
    # check_frames.main 使用模块级 VLS/BAG_CYCLES，已替换为 32 VL 配置
    sys.argv = [sys.argv[0], sys.argv[1]]
    rc2 = cf.main()
    print("RESULT: " + ("PASS (32 VL)" if rc == 0 and rc2 == 0 else "FAIL"))
    return 0 if rc == 0 and rc2 == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
