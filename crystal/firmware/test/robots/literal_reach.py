#!/usr/bin/env python3
"""Worst L32R reach of the Crystal code in a firmware link map.

    literal_reach.py build/crystal_blink.map

L32R loads a literal at most 256 KiB (262144 bytes) before the instruction.
For each crystal_app.o .text section this prints the distance from the start
of its literal section(s) to the end of the code, worst first. With
CRYSTAL_SPLIT=1 every function has its own .literal.F/.text.F pair; the
Xtensa linker keeps the IDF order (all literals of a file, then its code) while
that fits and moves a pool next to its function once it would not.
"""
import re
import sys

L = open(sys.argv[1]).read().split("\n")
start = next(k for k, l in enumerate(L) if l.startswith(".flash.text"))
secs = {}  # name -> (addr, size) for crystal_app.o
name = None
for l in L[start + 1:]:
    if l.startswith(".") and not l.startswith(".flash.text"):
        break  # next output section
    m = re.match(r"^ (\.(?:literal|text)\S*)(?:\s+(0x\S+)\s+(0x\S+)\s+(\S+))?\s*$", l)
    if m:
        name = m.group(1)
        if not m.group(2):
            continue  # long name: address on the next line
        rest = m.groups()[1:]
    elif name and re.match(r"^\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+\S", l):
        rest = l.split()[:3]
    else:
        continue
    if "crystal_app.o" in rest[2]:
        secs[name] = (int(rest[0], 16), int(rest[1], 16))
    name = None

lits = {n[len(".literal"):]: v for n, v in secs.items() if n.startswith(".literal") and v[1]}
txts = {n[len(".text"):]: v for n, v in secs.items() if n.startswith(".text") and v[1]}
rows = []
for fn, (a, sz) in txts.items():
    lit = lits.get(fn)
    if lit is None and len(lits) == 1:
        lit = next(iter(lits.values()))  # one shared .literal (CRYSTAL_SPLIT=0)
    if lit:
        rows.append((a + sz - lit[0], "text" + fn))
rows.sort(reverse=True)
total = sum(v[1] for v in txts.values())
print(f"crystal .text {total} bytes in {len(txts)} sections, {len(lits)} literal sections")
for reach, fn in rows[:3]:
    print(f"  reach {reach:7d} ({100 * reach / 262144:.0f}% of 256 KiB)  {fn[:80]}")
sys.exit(1 if rows and rows[0][0] > 262144 else 0)
