#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Prints the CPU time (user plus system, in seconds) of a process and all
its descendants, from /proc (Linux). run_browser.sh samples the browser at
two signals of the page and prints the share of one core in between.

    python3 -I proc_cpu.py <pid>
"""
import os
import sys


def main():
    root = int(sys.argv[1])
    tick = os.sysconf('SC_CLK_TCK')
    parent, cpu = {}, {}
    for entry in os.listdir('/proc'):
        if not entry.isdigit():
            continue
        try:
            with open(f'/proc/{entry}/stat') as f:
                stat = f.read()
        except OSError:
            continue
        # The command may hold spaces and parentheses: split after the last ')'.
        fields = stat[stat.rindex(')') + 2:].split()
        pid = int(entry)
        parent[pid] = int(fields[1])
        cpu[pid] = (int(fields[11]) + int(fields[12])) / tick
    total = 0.0
    for pid in cpu:
        p = pid
        while p > 1 and p != root:
            p = parent.get(p, 0)
        if p == root:
            total += cpu[pid]
    print(f'{total:.3f}')


if __name__ == '__main__':
    main()
