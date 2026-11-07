#!/usr/bin/env python3
"""Host check of the Settings web server's pages (main/settings_html.c):
builds test/apps/settings_pages.c with it, renders /, /robots (all 8 slots
full, long names that need escaping, an 8 KB robot in the editor, a
message), /robots with empty slots and /compete into test/apps/bin/, and
checks that each page is complete (ends as it should, every slot row there)
and well formed (balanced tags, no raw < & from the data), plus the links
and commands /compete must carry.

    python3 crystal/firmware/test/apps/settings_pages.py
"""
import html.parser
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "..", "main")
BIN = os.path.join(HERE, "bin")
os.makedirs(BIN, exist_ok=True)
exe = os.path.join(BIN, "settings_pages")
subprocess.run(["gcc", "-Wall", "-O1", "-I" + MAIN, "-o", exe, os.path.join(HERE, "settings_pages.c"),
                os.path.join(MAIN, "settings_html.c")], check=True)
subprocess.run([exe, BIN], check=True)

fails = []
VOID = {"meta", "br", "img", "input", "link"}
OPTIONAL_END = {"p", "tr", "td", "li", "option"}


class Check(html.parser.HTMLParser):
    def __init__(self, name):
        super().__init__()
        self.name = name
        self.stack = []
        self.text = []

    def handle_starttag(self, tag, attrs):
        if tag in VOID:
            return
        while tag in ("tr", "td", "option") and self.stack and self.stack[-1] in ("td", "option") and \
                (tag != "td" or self.stack[-1] == "td"):
            self.stack.pop()
            if tag == "td":
                break
        if tag == "tr":
            while self.stack and self.stack[-1] in ("td", "tr"):
                self.stack.pop()
        self.stack.append(tag)

    def handle_endtag(self, tag):
        while self.stack and self.stack[-1] != tag and self.stack[-1] in OPTIONAL_END:
            self.stack.pop()
        if not self.stack or self.stack[-1] != tag:
            fails.append("%s: unbalanced </%s> (open: %s)" % (self.name, tag, self.stack[-3:]))
            return
        self.stack.pop()

    def handle_data(self, d):
        self.text.append(d)


def check(name, must_end, needs=()):
    page = open(os.path.join(BIN, name), encoding="ascii").read()
    if not page.rstrip().endswith(must_end):
        fails.append("%s: incomplete, ends with %r" % (name, page[-60:]))
    for n in needs:
        if n not in page:
            fails.append("%s: missing %r" % (name, n))
    c = Check(name)
    c.feed(page)
    c.close()
    left = [t for t in c.stack if t not in OPTIONAL_END]
    if left:
        fails.append("%s: unclosed tags %s" % (name, left))
    print("%-18s %6d bytes" % (name, len(page)))
    return page, "".join(c.text)


check("root.html", "tournaments</p>", ("Jason&lt;", "Kridner&amp;Co", "my &quot;wifi&quot;", "name=aj value=1 checked",
                                       "href=/robots", "href=/compete"))
page, text = check("robots.html", "<a href=/>Settings</a></p>",
                   ["<tr><td>Slot %d<td>" % k for k in range(8)] +
                   ["Sniper&lt;&amp;&gt;&quot;Quote&#39;", "LastSlotLongName", "&lt;script&gt;alert(1)",
                    "<option value=7 selected>", "</textarea>", "Saved &quot;LastSlotLongName&quot; to slot 7."])
if "<script>" in page:
    fails.append("robots.html: a name went out unescaped")
if page.count("<a href='/robots?slot=") != 8:
    fails.append("robots.html: not 8 slot rows")
if text.count("x = 1 < 2 && 3 > 2") < 200:
    fails.append("robots.html: the robot in the editor is cut short")
check("robots_empty.html", "<a href=/>Settings</a></p>", ["<i>empty</i>", "<option value=0 selected>"])
check("compete.html", "<a href=/robots>Robots</a></p>",
      ("https://jkridner.beagleboard.io/crystal-robots/", "crystal/net/snakes/README.md", "href=/robots",
       "robot tourney", "robot tourney net", "snakes add", "snakes league", "POST /move", "scan(dir, 10)"))
if os.path.getsize(os.path.join(BIN, "compete.html")) > 8192:
    fails.append("compete.html: over 8 KB")

for f in fails:
    print("FAIL", f)
print("settings pages:", "ok" if not fails else "%d problems" % len(fails))
sys.exit(1 if fails else 0)
