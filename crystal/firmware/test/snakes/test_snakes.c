// Host tests for main/snakes.c: shell command, URLs, the bot API JSON, and
// the HTTP loop against the example bot (crystal/net/snakes/example_bot.py)
// started by run.sh on PORT_OK (answers at once) and PORT_SLOW (--delay
// 800, past the 500 ms timeout); PORT_DEAD has nothing listening.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cJSON.h"
#include "snakes.h"

static int fails, checks;
#define CHECK(c) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static const char *port_ok, *port_slow, *port_dead;

static void *alloc(int n) { return calloc(1, n); }

static void test_cmd(void)
{
    snk_cfg_t c = {0};
    char msg[512];
    CHECK(snk_cmd("", &c, msg, sizeof msg) == 0);
    CHECK(strstr(msg, "0 bots"));
    CHECK(snk_cmd("add alice http://10.0.0.5:8000", &c, msg, sizeof msg) == 1);
    CHECK(c.n == 1 && !strcmp(c.bot[0].name, "alice") && !strcmp(c.bot[0].url, "http://10.0.0.5:8000"));
    CHECK(snk_cmd("add bob https://bob.example.com/snake/", &c, msg, sizeof msg) == 1);
    CHECK(snk_cmd("add ALICE http://10.0.0.6:9000", &c, msg, sizeof msg) == 1); // replaces
    CHECK(c.n == 2 && !strcmp(c.bot[0].url, "http://10.0.0.6:9000"));
    CHECK(snk_cmd("add bad name http://x", &c, msg, sizeof msg) == -1);
    CHECK(snk_cmd("add x\"y http://10.0.0.1", &c, msg, sizeof msg) == -1);
    CHECK(snk_cmd("add carl ftp://10.0.0.1", &c, msg, sizeof msg) == -1);
    CHECK(snk_cmd("add house http://10.0.0.1", &c, msg, sizeof msg) == -1);
    CHECK(snk_cmd("list", &c, msg, sizeof msg) == 0);
    CHECK(strstr(msg, "ALICE") && strstr(msg, "bob.example.com"));
    CHECK(snk_cmd("rm 1", &c, msg, sizeof msg) == 1);
    CHECK(c.n == 1 && !strcmp(c.bot[0].name, "bob"));
    CHECK(snk_cmd("rm nobody", &c, msg, sizeof msg) == -1);
    CHECK(snk_cmd("rm bob", &c, msg, sizeof msg) == 1 && c.n == 0);
    for (int i = 0; i < SNK_BOTS; i++) {
        char line[64];
        snprintf(line, sizeof line, "add b%d http://10.0.0.%d", i, i + 1);
        CHECK(snk_cmd(line, &c, msg, sizeof msg) == 1);
    }
    CHECK(snk_cmd("add one-more http://10.0.0.99", &c, msg, sizeof msg) == -1);
    CHECK(snk_cmd("play", &c, msg, sizeof msg) == 2);
    CHECK(snk_cmd("frobnicate", &c, msg, sizeof msg) == -1);
}

static void test_url(void)
{
    snk_url_t u;
    char p[128];
    CHECK(snk_parse_url("http://192.168.1.20:8000", &u) && !u.https && u.port == 8000 && !strcmp(u.host, "192.168.1.20") && !u.path[0]);
    snk_path(&u, "move", p, sizeof p);
    CHECK(!strcmp(p, "/move"));
    snk_path(&u, "", p, sizeof p);
    CHECK(!strcmp(p, "/"));
    CHECK(snk_parse_url("https://snake.example.com/bots/v2/", &u) && u.https && u.port == 443 && !strcmp(u.path, "/bots/v2"));
    snk_path(&u, "start", p, sizeof p);
    CHECK(!strcmp(p, "/bots/v2/start"));
    CHECK(snk_parse_url("http://host", &u) && u.port == 80);
    CHECK(!snk_parse_url("http://host:0", &u));
    CHECK(!snk_parse_url("http://host:99999", &u));
    CHECK(!snk_parse_url("http://:80", &u));
    CHECK(!snk_parse_url("host:80", &u));
    CHECK(!snk_parse_url("http://host/a b", &u));
}

// A board like SnakeRules.snapshot makes: 2 snakes, the second dead.
static const int32_t SNAP[] = {7, 2, 2, 5, 5, 0, 10,
                               1, 93, 3, 1, 2, 1, 1, 1, 0,
                               0, 40, 3, 8, 8, 8, 9, 8, 10};
#define NSNAP ((int)(sizeof SNAP / sizeof SNAP[0]))

static void test_json(void)
{
    snk_game_t g = {.game_id = "badge-1", .timeout_ms = 500, .name = {"alice", "house"}, .shout = {"hi", ""}, .latency = {12, 0}};
    static char out[8192], body[8192];
    int off[4], len[4];
    int common = snk_json_turn(&g, SNAP, NSNAP, out, sizeof out, off, len);
    CHECK(common > 0);
    int bn = snk_json_body(out, common, off[0], len[0], body, sizeof body);
    CHECK(bn > common);
    cJSON *j = cJSON_Parse(body);
    CHECK(j != NULL);
    if (!j) { printf("%s\n", body); return; }
    CHECK(!strcmp(cJSON_GetObjectItem(cJSON_GetObjectItem(j, "game"), "id")->valuestring, "badge-1"));
    CHECK(cJSON_GetObjectItem(cJSON_GetObjectItem(j, "game"), "timeout")->valueint == 500);
    CHECK(!strcmp(cJSON_GetObjectItem(cJSON_GetObjectItem(cJSON_GetObjectItem(j, "game"), "ruleset"), "name")->valuestring, "standard"));
    CHECK(cJSON_GetObjectItem(j, "turn")->valueint == 7);
    cJSON *b = cJSON_GetObjectItem(j, "board");
    CHECK(cJSON_GetObjectItem(b, "width")->valueint == 11 && cJSON_GetObjectItem(b, "height")->valueint == 11);
    CHECK(cJSON_GetArraySize(cJSON_GetObjectItem(b, "food")) == 2);
    CHECK(cJSON_GetArraySize(cJSON_GetObjectItem(b, "hazards")) == 0);
    cJSON *sn = cJSON_GetObjectItem(b, "snakes");
    CHECK(cJSON_GetArraySize(sn) == 1); // the dead one is off the board
    cJSON *you = cJSON_GetObjectItem(j, "you");
    CHECK(!strcmp(cJSON_GetObjectItem(you, "id")->valuestring, "snake-1"));
    CHECK(!strcmp(cJSON_GetObjectItem(you, "name")->valuestring, "alice"));
    CHECK(cJSON_GetObjectItem(you, "health")->valueint == 93);
    CHECK(cJSON_GetObjectItem(you, "length")->valueint == 3);
    CHECK(!strcmp(cJSON_GetObjectItem(you, "latency")->valuestring, "12"));
    CHECK(!strcmp(cJSON_GetObjectItem(you, "shout")->valuestring, "hi"));
    CHECK(cJSON_GetObjectItem(cJSON_GetObjectItem(you, "head"), "y")->valueint == 2);
    cJSON *b0 = cJSON_GetArrayItem(cJSON_GetObjectItem(you, "body"), 2);
    CHECK(cJSON_GetObjectItem(b0, "x")->valueint == 1 && cJSON_GetObjectItem(b0, "y")->valueint == 0);
    cJSON_Delete(j);
    // the dead snake still gets its own "you" (for /end)
    bn = snk_json_body(out, common, off[1], len[1], body, sizeof body);
    j = cJSON_Parse(body);
    CHECK(j && !strcmp(cJSON_GetObjectItem(cJSON_GetObjectItem(j, "you"), "id")->valuestring, "snake-2"));
    cJSON_Delete(j);
    CHECK(snk_json_turn(&g, SNAP, NSNAP, out, 100, off, len) < 0);
    CHECK(snk_json_turn(&g, SNAP, 10, out, sizeof out, off, len) < 0);

    char sh[SNK_SHOUT];
    CHECK(snk_parse_move("{\"move\":\"left\",\"shout\":\"go \\\"west\\\"\"}", sh, sizeof sh) == 2);
    CHECK(!strcmp(sh, "go west"));
    CHECK(snk_parse_move("{\"move\":\"UP\"}", sh, sizeof sh) == 0 && !sh[0]);
    CHECK(snk_parse_move("{\"move\":\"sideways\"}", sh, sizeof sh) == -1);
    CHECK(snk_parse_move("not json", sh, sizeof sh) == -1);
    char au[24];
    CHECK(snk_parse_info("{\"apiversion\":\"1\",\"author\":\"me\"}", au, sizeof au, NULL, 0) && !strcmp(au, "me"));
    CHECK(!snk_parse_info("<html>", au, sizeof au, NULL, 0));
}

static void test_http(void)
{
    static snk_session_t s;
    char url[64];
    CHECK(snk_session_alloc(&s, alloc));
    snk_session_reset(&s, 4, 0x1234);
    snprintf(url, sizeof url, "http://127.0.0.1:%s", port_ok);
    snk_session_set(&s, 0, "fast", url);
    snprintf(url, sizeof url, "http://localhost:%s/", port_slow);
    snk_session_set(&s, 1, "slow", url);
    snprintf(url, sizeof url, "http://127.0.0.1:%s", port_dead);
    snk_session_set(&s, 2, "dead", url);
    snk_session_set(&s, 3, "house", NULL);
    snk_session_resolve(&s);
    CHECK(s.resolved[0] && s.resolved[1] && s.resolved[2] && !s.bot[3]);

    snk_session_info(&s, 2000);
    CHECK(s.err[0] == SNK_E_NONE && !strcmp(s.author[0], "fast"));
    CHECK(s.err[1] == SNK_E_NONE && !strcmp(s.author[1], "slow")); // GET / is not delayed
    CHECK(s.err[2] == SNK_E_CONNECT);
    printf("info: fast %d ms, slow %d ms, dead %s\n", s.ms[0], s.ms[1], snk_err_name(s.err[2]));

    int32_t snap[] = {0, 4, 1, 5, 5,
                      1, 100, 3, 1, 1, 1, 1, 1, 1,
                      1, 100, 3, 9, 9, 9, 9, 9, 9,
                      1, 100, 3, 1, 9, 1, 9, 1, 9,
                      1, 100, 3, 9, 1, 9, 1, 9, 1};
    int n = sizeof snap / sizeof snap[0];
    CHECK(snk_session_call(&s, "start", snap, n, 1000) == 3);
    CHECK(s.err[0] == SNK_E_NONE);
    int64_t t0 = snk_now_ms();
    CHECK(snk_session_call(&s, "move", snap, n, 500) == 3);
    int dt = (int)(snk_now_ms() - t0);
    printf("move: fast %s %d ms (move %d, \"%s\"), slow %s, dead %s, turn took %d ms\n", snk_err_name(s.err[0]), s.ms[0],
           s.move[0], s.shout[0], snk_err_name(s.err[1]), snk_err_name(s.err[2]), dt);
    CHECK(s.move[0] >= 0 && s.move[0] <= 3);
    CHECK(s.move[0] != 1 && s.move[0] != 2); // (1,1): down and left are walls
    CHECK(!strncmp(s.shout[0], "turn 0", 6));
    CHECK(s.err[1] == SNK_E_TIMEOUT && s.move[1] == -1);
    CHECK(s.err[2] == SNK_E_CONNECT && s.move[2] == -1);
    CHECK(s.move[3] == -1);
    CHECK(dt >= 480 && dt < 700); // one deadline for all bots
    CHECK(s.timeouts[0] == 0 && s.timeouts[1] == 1 && s.timeouts[2] == 1);
    snap[5] = 0; // snake 1 dead: not asked for a move
    CHECK(snk_session_call(&s, "move", snap, n, 500) == 2);
    CHECK(snk_session_call(&s, "end", snap, n, 500) == 3);
    CHECK(s.err[0] == SNK_E_NONE);
}

int main(int argc, char **argv)
{
    port_ok = argc > 1 ? argv[1] : "18701";
    port_slow = argc > 2 ? argv[2] : "18702";
    port_dead = argc > 3 ? argv[3] : "18703";
    test_cmd();
    test_url();
    test_json();
    test_http();
    printf("test_snakes: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
