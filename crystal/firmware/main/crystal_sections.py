#!/usr/bin/env python3
"""Give every function in Crystal's LLVM IR its own `.text.<name>` section.

    crystal_sections.py in.ll out.ll

Used by main/CMakeLists.txt when CRYSTAL_LLC is set. It does what llc
--function-sections does, but with section names the ESP-IDF tools can read:
Crystal's symbols contain spaces and punctuation (`*Menu::tick<Int32, Int32>:Nil`)
and esp_idf_size (`idf.py size`) fails to parse a map file with spaces in
input section names. The Xtensa backend puts each function's literal pool in
the matching `.literal.<name>` section, and the IDF linker script places
`.literal.*` and `.text.*` sections of one object in file order, so every
pool sits right before its function, well inside the L32R reach, however
large the whole object gets. Names that sanitise to the same string share a
section, which is harmless (the pair stays together).
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
define = re.compile(r'^define .*@(?:"((?:[^"\\]|\\.)*)"|([-\w$.]+))\(')
tail = re.compile(r'(#\d+)((?: ![\w.]+ !\d+)*) \{$')
n = 0
with open(src) as f, open(dst, "w") as out:
    for line in f:
        if line.startswith("define "):
            m = define.match(line)
            t = tail.search(line)
            if not m or not t or " section " in line:
                sys.exit(f"crystal_sections.py: can't place: {line[:200]}")
            name = re.sub(r"[^A-Za-z0-9_.]", "_", m.group(1) or m.group(2)).strip("_")
            line = line[: t.start()] + f'{t.group(1)} section ".text.{name}"{t.group(2)} {{\n'
            n += 1
        out.write(line)
print(f"crystal_sections.py: {n} functions in their own sections")
