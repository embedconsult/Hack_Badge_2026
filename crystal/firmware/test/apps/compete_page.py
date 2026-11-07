#!/usr/bin/env python3
"""Host check of the Settings server's "How to compete" page (main/settings.c,
k_compete, served at http://192.168.4.1/compete): the C string literal is
pulled out of the source, compiled by gcc (so the escapes are C's own),
written to test/apps/bin/compete.html and checked: size, the links it must
carry, the commands it names, and balanced tags.

    python3 crystal/firmware/test/apps/compete_page.py
"""
import html.parser
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "main", "settings.c")
BIN = os.path.join(HERE, "bin")
os.makedirs(BIN, exist_ok=True)

c = open(SRC).read()
m = re.search(r"static const char k_compete\[\] =\n(.*?);\n", c, re.S)
if not m:
    sys.exit("FAIL: k_compete not found in settings.c")
prog = os.path.join(BIN, "compete.c")
with open(prog, "w") as f:
    f.write("#include <stdio.h>\nstatic const char k[] =\n%s;\nint main(void){fwrite(k,1,sizeof k-1,stdout);return 0;}\n"
            % m.group(1))
subprocess.run(["gcc", "-o", os.path.join(BIN, "compete"), prog], check=True)
page = subprocess.run([os.path.join(BIN, "compete")], capture_output=True, check=True).stdout.decode()
with open(os.path.join(BIN, "compete.html"), "w") as f:
    f.write(page)

fails = []
if len(page) > 8192:
    fails.append("page is %d bytes (keep it under 8 KB)" % len(page))
for need in ("https://jkridner.beagleboard.io/crystal-robots/", "crystal/net/snakes/README.md", "href=/robots",
             "robot tourney", "robot tourney net", "snakes add", "snakes league", "POST /move", "scan(dir, 10)"):
    if need not in page:
        fails.append("missing: " + need)

VOID = {"meta", "br", "img", "input", "link"}
OPTIONAL_END = {"p", "tr", "td", "li"}


class Check(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []

    def handle_starttag(self, tag, attrs):
        if tag in VOID:
            return
        if tag in ("tr", "td") and self.stack and self.stack[-1] == tag:
            self.stack.pop()
        if tag == "tr" and self.stack and self.stack[-1] == "td":
            self.stack.pop()
            if self.stack and self.stack[-1] == "tr":
                self.stack.pop()
        self.stack.append(tag)

    def handle_endtag(self, tag):
        while self.stack and self.stack[-1] != tag and self.stack[-1] in OPTIONAL_END:
            self.stack.pop()
        if not self.stack or self.stack[-1] != tag:
            fails.append("unbalanced </%s> (open: %s)" % (tag, self.stack[-3:]))
            return
        self.stack.pop()


ch = Check()
ch.feed(page)
left = [t for t in ch.stack if t not in OPTIONAL_END]
if left:
    fails.append("unclosed tags: %s" % left)

for f in fails:
    print("FAIL", f)
print("compete page: %d bytes, %s" % (len(page), "ok" if not fails else "%d problems" % len(fails)))
sys.exit(1 if fails else 0)
