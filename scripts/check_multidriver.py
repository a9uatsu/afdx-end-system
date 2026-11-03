#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_multidriver.py - 静态检查"同一信号被多个 always 块驱动"

综合器（eLinx/Vivado/Quartus）对同一个寄存器被两个 always 块赋值会直接报错，
而部分仿真器（如 Icarus）会静默接受，导致"仿真通过、综合失败"。
本脚本用启发式扫描提前发现这类问题。

用法: check_multidriver.py <rtl目录>
"""
import os
import re
import sys


def module_bodies(text):
    return re.findall(r"\bmodule\s+(\w+)\b(.*?)\bendmodule\b", text, re.S)


def main():
    if len(sys.argv) < 2:
        print("用法: check_multidriver.py <rtl目录>")
        return 2
    root = sys.argv[1]
    n_bad = 0
    n_file = 0

    for fn in sorted(os.listdir(root)):
        if not fn.endswith((".v", ".sv")):
            continue
        n_file += 1
        path = os.path.join(root, fn)
        text = open(path, encoding="utf-8").read()

        for mname, body in module_bodies(text):
            # 以 "always" 为界切块；块内出现的 <= 赋值即视为该块驱动
            chunks = re.split(r"\balways\b", body)
            drivers = {}
            for bi, ch in enumerate(chunks[1:], start=1):
                for name in set(re.findall(r"\b([A-Za-z_]\w*)\s*<=", ch)):
                    drivers.setdefault(name, set()).add(bi)

            # 连续赋值也算一路驱动
            for name in set(re.findall(r"\bassign\s+([A-Za-z_]\w*)\s*=", body)):
                drivers.setdefault(name, set()).add(0)

            for name, src in sorted(drivers.items()):
                if len(src) > 1:
                    where = ", ".join("assign" if s == 0 else f"always#{s}" for s in sorted(src))
                    print(f"[MULTIDRIVER] {fn} :: {mname}.{name} 驱动器: {where}")
                    n_bad += 1

    print("")
    print("==================== 多驱动静态检查 ====================")
    print(f"扫描文件数 = {n_file}")
    print(f"问题数     = {n_bad}")
    print("RESULT: " + ("PASS" if n_bad == 0 else "FAIL"))
    print("=======================================================")
    return 0 if n_bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
