// Settings web pages as HTML: see settings_html.h.
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "settings_html.h"

int32_t cr_robot_slots(void); // main/robots.c
int32_t cr_robot_len(int32_t k);
bool cr_robot_name(int32_t k, char *out);

void html_init(html_t *h, void *(*grow)(void *old, size_t n))
{
    memset(h, 0, sizeof *h);
    h->grow = grow;
}

static bool room(html_t *h, int k)
{
    if (h->oom) return false;
    if (h->n + k + 1 <= h->cap) return true;
    int cap = h->cap ? h->cap : 4096;
    while (cap < h->n + k + 1) cap *= 2;
    char *p = h->grow(h->p, cap);
    if (!p) {
        h->oom = true;
        return false;
    }
    h->p = p, h->cap = cap;
    return true;
}

void html_putn(html_t *h, const char *s, int n)
{
    if (n <= 0 || !room(h, n)) return;
    memcpy(h->p + h->n, s, n);
    h->n += n;
    h->p[h->n] = 0;
}

void html_put(html_t *h, const char *s) { html_putn(h, s, (int)strlen(s)); }

void html_printf(html_t *h, const char *fmt, ...)
{
    char b[160];
    va_list a;
    va_start(a, fmt);
    int n = vsnprintf(b, sizeof b, fmt, a);
    va_end(a);
    html_putn(h, b, n < (int)sizeof b ? n : (int)sizeof b - 1);
}

static void esc(html_t *h, const char *s, int n, bool text)
{
    for (int i = 0; i < n; i++) {
        char c = s[i];
        if (c == '&') html_put(h, "&amp;");
        else if (c == '<') html_put(h, "&lt;");
        else if (c == '>') html_put(h, "&gt;");
        else if (!text && c == '"') html_put(h, "&quot;");
        else if (!text && c == '\'') html_put(h, "&#39;");
        else if ((c >= 0x20 && c <= 0x7E) || (text && (c == '\n' || c == '\t'))) html_putn(h, &c, 1);
    }
}

void html_esc(html_t *h, const char *s) { esc(h, s, (int)strlen(s), false); }
void html_text(html_t *h, const char *s, int n) { esc(h, s, n, true); }

// ---- / ------------------------------------------------------------------------------

static const char k_head[] =
    "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>Badge settings</title><style>body{font:16px system-ui,sans-serif;max-width:32em;margin:auto;padding:1em}"
    "fieldset{border:1px solid #bbb;border-radius:8px;margin:0 0 1em}input{font:inherit;width:100%;box-sizing:border-box;"
    "padding:.4em;margin:.2em 0 .6em}input[type=checkbox]{width:auto}button{font:inherit;background:#b00;color:#fff;"
    "border:0;border-radius:8px;padding:.7em 1.4em}small{color:#666}</style><h2>Badge settings</h2>";

void html_root(html_t *h, const html_root_t *v)
{
    html_put(h, k_head);
    if (v->msg && v->msg[0]) {
        html_put(h, "<p><b>");
        html_esc(h, v->msg);
        html_put(h, "</b></p>");
    }
    html_put(h, "<form method=post action=/save><fieldset><legend>Nametag</legend>Line 1<input name=n1 maxlength=12 value=\"");
    html_esc(h, v->line1);
    html_put(h, "\">Line 2<input name=n2 maxlength=12 value=\"");
    html_esc(h, v->line2);
    html_put(h, "\"><small>Up to 12 characters each (A-Z, digits, punctuation).</small></fieldset>"
                "<fieldset><legend>Wi-Fi the badge joins</legend><small>Used by online update and network mode.</small><br>"
                "SSID<input name=ssid maxlength=32 value=\"");
    html_esc(h, v->ssid);
    html_put(h, "\">Password<input name=pass type=password maxlength=63 autocomplete=off placeholder='");
    html_put(h, v->ssid[0] ? "(unchanged if empty)" : "");
    html_put(h, "'><label><input type=checkbox name=open value=1> Open network (no password)</label></fieldset>"
                "<fieldset><legend>Network mode</legend><label><input type=checkbox name=net value=1");
    if (v->net) html_put(h, " checked");
    html_put(h, "> Badge link on (UDP + ESP-NOW; starts when you leave Settings)</label><br>"
                "<label><input type=checkbox name=aj value=1");
    if (v->autojoin) html_put(h, " checked");
    html_put(h, "> Join robot tournaments from nearby badges</label><br><small>When the badge shows Home or ROBOTS, "
                "or nobody has touched it for a minute; otherwise the top bar says TOURNEY NEARBY.</small></fieldset>"
                "<button>Save</button></form>"
                "<p><a href=/robots>Robots</a>: battle robots for the ROBOTS app &middot; "
                "<a href=/compete>How to compete</a>: robots, snake bots, tournaments</p>");
}

// ---- /robots ------------------------------------------------------------------------

static const char k_rhead[] =
    "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>Badge robots</title><style>body{font:16px system-ui,sans-serif;max-width:48em;margin:auto;padding:1em}"
    "textarea{width:100%;box-sizing:border-box;height:28em;font:14px ui-monospace,monospace}"
    "select,button{font:inherit;margin:.3em 0}button{background:#b00;color:#fff;border:0;border-radius:8px;"
    "padding:.6em 1.2em}td{padding:.1em .6em}small{color:#666}</style><h2>Robots</h2>"
    "<p><small>Robots in the <a href='https://jkridner.beagleboard.io/crystal-robots/'>crystal-robots</a> language "
    "(same as the website). Saved robots join the ROBOTS app's line-ups; the shell's "
    "<code>robot run</code> picks a battle. <a href=/compete>How to compete</a></small></p>";

void html_robots(html_t *h, int slot, const char *src, int n, const char *msg)
{
    char name[17];
    html_put(h, k_rhead);
    if (msg && msg[0]) {
        html_put(h, "<p><b>");
        html_esc(h, msg);
        html_put(h, "</b></p>");
    }
    html_put(h, "<table>");
    for (int k = 0; k < cr_robot_slots(); k++) {
        int len = cr_robot_len(k);
        name[0] = 0;
        if (len >= 0 && !cr_robot_name(k, name)) name[0] = 0;
        name[16] = 0;
        html_printf(h, "<tr><td>Slot %d<td>", k);
        if (len < 0) {
            html_put(h, "<i>empty</i>");
        } else {
            html_esc(h, name[0] ? name : "(no name)");
            html_printf(h, " <small>%d bytes</small>", len);
        }
        html_printf(h, "<td><a href='/robots?slot=%d'>%s</a></tr>", k, len < 0 ? "write" : "edit");
    }
    html_put(h, "</table><form method=post action=/robots>Slot <select name=slot>");
    for (int k = 0; k < cr_robot_slots(); k++)
        html_printf(h, "<option value=%d%s>%d</option>", k, k == slot ? " selected" : "", k);
    html_put(h, "</select><textarea name=src spellcheck=false placeholder='main(\"Name\") do&#10;  drive(rand(360), 50)&#10;end'>");
    if (src && n > 0) html_text(h, src, n);
    html_put(h, "</textarea><button>Check and save</button> <small>An empty editor empties the slot.</small></form>"
                "<p><a href=/>Settings</a></p>");
}

// ---- /compete (static) --------------------------------------------------------------

const char html_compete[] =
    "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>How to compete</title><style>body{font:16px system-ui,sans-serif;max-width:44em;margin:auto;padding:1em}"
    "code,pre{font:14px ui-monospace,monospace;background:#f3f3f3}pre{padding:.6em;overflow:auto}"
    "td{padding:.15em .5em;vertical-align:top}h3{margin-top:1.4em}</style>"
    "<h2>How to compete</h2><p>Two games on this badge, two ways to win: write a <b>robot</b> "
    "(ROBOTS) or a <b>snake bot</b> (SNAKES).</p>"
    "<h3>ROBOTS: battle robots</h3>"
    "<p>Robots are small programs in the <a href='https://jkridner.beagleboard.io/crystal-robots/'>crystal-robots</a> "
    "language (Ruby-like, after CROBOTS). Try them on that website: the badge plays every battle exactly "
    "like it. Then paste yours on <a href=/robots>/robots</a> (checked and saved to a slot).</p>"
    "<pre>global(dir, 0)\n\nmain(\"Spinner\") do\n  while true\n    r = scan(dir, 10)    # anyone within 10 deg?\n"
    "    if r > 0 &amp;&amp; r &lt;= 700\n      cannon(dir, r)     # fire at that range\n    else\n      dir = (dir + 20) % 360\n"
    "    end\n    if damage &gt; 50\n      drive(rand(360), 40)\n    end\n  end\nend</pre>"
    "<table><tr><td><code>scan(deg, res)</code><td>distance (m) to the nearest robot within deg &plusmn; res (res &le; 10), 0 if none"
    "<tr><td><code>cannon(deg, range)</code><td>fire a missile (range &le; 700 m, two in the air at most); 1 fired, 0 not"
    "<tr><td><code>drive(deg, speed)</code><td>speed 0..100 %; the heading only changes at 50 % or less"
    "<tr><td><code>damage speed loc_x loc_y</code><td>own damage (100: destroyed), speed, position (field 1000 x 1000 m, 0,0 lower left)"
    "<tr><td><code>rand(n) sqrt(x)</code><td>0..n-1; square root"
    "<tr><td><code>sin cos tan atan</code><td>degrees, scaled by 100000 (<code>atan(100000 * y / x)</code>)"
    "<tr><td><code>puts x</code> <code>sleep</code><td>show a value on the badge; wait"
    "<tr><td><code>global(name, v)</code><td>a global with a start value; <code>NAME = 3</code> constants; <code>def f(a) ... end</code>"
    "<tr><td>control<td><code>if/elsif/else</code>, <code>while</code>, <code>until</code>, <code>case/when</code>, "
    "<code>break</code>, <code>return</code>; <code>main(\"Name\") do ... end</code> is the robot</table>"
    "<p>0 deg is east, 90 north. Walls and collisions hurt; missiles explode where they land.</p>"
    "<p><b>Tournaments</b>: on ROBOTS press B after a battle (<b>TOURNEY</b>), or shell <code>robot tourney</code>: every "
    "saved robot and the 10 built-ins in a round robin of 4-robot battles, 3 points for the last one standing, 1 for "
    "surviving to the cycle limit, then a final of the top four. With network mode on and other badges around, "
    "<b>LINK TOURNEY</b> (<code>robot tourney net</code>) pulls in every badge's saved robots; every badge plays it "
    "and cross-checks. <code>robot standings [net]</code> prints the table.</p>"
    "<h3>SNAKES: snake bots over HTTP</h3>"
    "<p>A snake bot is a small web server you run (laptop, phone, Pi, cloud) that speaks the open snake-bot API: "
    "<code>GET /</code> (info), <code>POST /start</code>, <code>POST /move</code> answering "
    "<code>{\"move\": \"up|down|left|right\", \"shout\": \"...\"}</code> within 500 ms, <code>POST /end</code>. "
    "The board is 11 x 11 (y up), standard rules: eat to grow and heal, avoid walls, bodies and longer heads. "
    "Existing Battlesnake bots work as they are. API, rules and an example bot in Python: "
    "<a href='https://github.com/embedconsult/Hack_Badge_2026/blob/crystal/crystal/net/snakes/README.md'>"
    "crystal/net/snakes/README.md</a> in the badge repo.</p>"
    "<p>Bring it: <code>snakes add &lt;name&gt; http://&lt;ip&gt;:&lt;port&gt;</code> on the badge's USB shell, then "
    "<code>snakes play</code>, or <code>snakes league 10</code>: ten games against the other bots and the house snake, "
    "with an Elo table in the SNAKES lobby (bots are matched by name).</p>"
    "<p><a href=/>Settings</a> &middot; <a href=/robots>Robots</a></p>";
const int html_compete_len = sizeof html_compete - 1;
