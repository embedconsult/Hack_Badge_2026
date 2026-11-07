// SNAKES arena, portable part (main/snakes.c): the saved bot list and its
// shell command, bot URLs, the bot API's JSON (requests built from the
// rules engine's snapshot, replies parsed with cJSON) and a small HTTP/1.1
// client on BSD sockets that talks to all bots of a turn at once with one
// deadline. Builds on the badge (lwIP) and on the host (test/snakes/).
//
// The bot API is the open snake-bot move API: GET / (bot info), POST
// /start, /move, /end with {"game", "turn", "board", "you"}; /move answers
// {"move": "up|down|left|right", "shout": "..."}. Plain http:// only here;
// main/snakes_net.c adds https:// on the badge with esp_http_client.
#pragma once
#include <stdint.h>
#include <stdbool.h>

#define SNK_BOTS 6      // saved bots
#define SNK_NAME 16     // bot name, with the NUL
#define SNK_URL 128     // bot URL, with the NUL
#define SNK_SLOTS 4     // snakes per game (SnakeRules::MAX)
#define SNK_REQ_MAX 12288
#define SNK_RESP_MAX 2048
#define SNK_SHOUT 48

typedef struct {
    char name[SNK_NAME];
    char url[SNK_URL];
} snk_bot_t;

typedef struct {
    int n;
    snk_bot_t bot[SNK_BOTS];
} snk_cfg_t;

// Shell: the words after "snakes". Returns 1 if c changed (save it), 0 if
// not (list, help), 2 for "play" (the caller starts a game), 3 for "league
// [games]" (*games = how many, default 5), 4 "league reset", 5 "league
// show", -1 on bad syntax; msg = what to print (ends with a newline).
int snk_cmd_league(const char *args, int *games);
int snk_cmd(const char *args, snk_cfg_t *c, char *msg, int n);

typedef struct {
    bool https;
    char host[64];
    int port;
    char path[96]; // no trailing '/', "" for the root
} snk_url_t;

bool snk_parse_url(const char *url, snk_url_t *u);
// u->path + "/" + ep (ep "" = the bot's root, i.e. GET /), into out.
void snk_path(const snk_url_t *u, const char *ep, char *out, int n);

// ---- league (`snakes league`): a rating table over many games ------------------
// Elo (start 1500, pairwise between every two snakes of a game, K = 32 /
// (snakes - 1)), plus wins (sole longest survivor) and points (opponents
// outlasted). Entries by name; the house snake is "house".
#define SNK_LG 8
#define SNK_ELO0 1500

typedef struct {
    char name[SNK_NAME];
    int32_t elo;
    uint16_t games, wins, points, pad;
} snk_lg_ent_t;

typedef struct {
    uint32_t magic; // SNK_LG_MAGIC when valid
    int32_t n, games;
    snk_lg_ent_t e[SNK_LG];
} snk_league_t;
#define SNK_LG_MAGIC 0x31474C53u // "SLG1"

void snk_league_reset(snk_league_t *L);
// One game of n snakes: name[i], score[i] (higher = lasted longer; equal = tie).
void snk_league_game(snk_league_t *L, int n, const char *const *name, const int *score);
// Entry indices best first (Elo, then wins, then games); returns L->n.
int snk_league_order(const snk_league_t *L, int *order);
// The table as text (ends with a newline); its length.
int snk_league_text(const snk_league_t *L, char *out, int n);

// ---- JSON ------------------------------------------------------------------------

// What the game knows about each snake besides the board.
typedef struct {
    const char *game_id;
    int timeout_ms;
    const char *name[SNK_SLOTS];
    const char *shout[SNK_SLOTS];
    int latency[SNK_SLOTS];
} snk_game_t;

// Builds the request bodies of one turn from a SnakeRules.snapshot. out
// holds "{game, turn, board}" without its closing brace (only living
// snakes in board.snakes), then every snake's own JSON; you_off/you_len
// say where snake i's is. Returns the length of the common part, or -1 if
// out is too small.
int snk_json_turn(const snk_game_t *g, const int32_t *snap, int nsnap, char *out, int n,
                  int *you_off, int *you_len);

// Snake i's full request body ("<common>,\"you\":<snake i>}") into dst.
int snk_json_body(const char *turn_json, int common, int you_off, int you_len, char *dst, int n);

// /move reply -> 0 up, 1 down, 2 left, 3 right (SnakeRules), -1 if none.
// shout (may be NULL) gets the shout, "" if none.
int snk_parse_move(const char *body, char *shout, int n);

// GET / reply: true if it is bot info JSON; author / version copied.
bool snk_parse_info(const char *body, char *author, int an, char *version, int vn);

// ---- HTTP --------------------------------------------------------------------------

typedef struct {
    // in
    uint32_t ip;          // IPv4, network order (snk_resolve)
    int port;
    const char *host;     // for the Host header
    const char *path;
    const char *method;   // "GET" or "POST"
    const char *body;     // POST body (may be NULL)
    int blen;
    char *req;            // scratch for the request bytes, reqcap long
    int reqcap;
    // out
    int status;           // HTTP status, 0 = no answer (err says why)
    int err;              // 0, or SNK_E_*
    int ms;               // time to the full answer (or to the error)
    char resp[SNK_RESP_MAX]; // the body (de-chunked), NUL terminated
    int rn;
    // internal
    int fd, state, off, len, hdr_end, clen, chunked;
    char raw[SNK_RESP_MAX];
} snk_req_t;

enum { SNK_E_NONE = 0, SNK_E_RESOLVE, SNK_E_CONNECT, SNK_E_TIMEOUT, SNK_E_IO, SNK_E_HTTP, SNK_E_TOOBIG };
const char *snk_err_name(int e);

// ---- a game's (or the lobby's) bots ------------------------------------------------

// https:// requests (badge: esp_http_client in snakes_net.c; NULL = not
// supported). Returns the HTTP status (> 0) or -SNK_E_*; resp gets the body.
typedef int (*snk_https_fn)(int slot, const snk_url_t *u, const char *method, const char *path,
                            const char *body, int blen, char *resp, int rcap, int timeout_ms);

#define SNK_HOUSE (-1)

typedef struct {
    int n;                         // snakes in the game (the lobby: bots)
    bool bot[SNK_BOTS];            // false = the house snake (no HTTP)
    char name[SNK_BOTS][SNK_NAME];
    snk_url_t url[SNK_BOTS];
    uint32_t ip[SNK_BOTS];
    bool resolved[SNK_BOTS];
    char game_id[24];
    int timeout_ms;                // the game's move timeout (500)
    snk_https_fn https;
    // results of the last call
    int move[SNK_BOTS];            // SnakeRules direction, -1 = none (keep going)
    int err[SNK_BOTS];             // SNK_E_*
    int status[SNK_BOTS];
    int ms[SNK_BOTS];
    char shout[SNK_BOTS][SNK_SHOUT];
    char author[SNK_BOTS][24];
    int timeouts[SNK_BOTS];        // /move calls without a usable move, this game
    // buffers (snk_session_alloc)
    char *json;                    // the turn's JSON
    char *body;                    // one request body
    snk_req_t *req;                // SNK_BOTS
} snk_session_t;

bool snk_session_alloc(snk_session_t *s, void *(*alloc)(int));
// A new game (or lobby) with n entries; then snk_session_set per entry.
void snk_session_reset(snk_session_t *s, int n, uint32_t seed);
// Entry i: url NULL = the house snake.
void snk_session_set(snk_session_t *s, int i, const char *name, const char *url);
// Resolves the bots' host names (blocking DNS; once per game).
void snk_session_resolve(snk_session_t *s);
// GET / of every bot: author + reachability (err / ms).
void snk_session_info(snk_session_t *s, int timeout_ms);
// POST /<ep> ("start", "move", "end") to the bots, all at once, with the
// board from a SnakeRules.snapshot; "move" only asks the living ones and
// fills move[] (-1 = no usable answer in time). Returns the bots asked.
int snk_session_call(snk_session_t *s, const char *ep, const int32_t *snap, int nsnap, int timeout_ms);

int64_t snk_now_ms(void);
bool snk_resolve(const char *host, uint32_t *ip);
// Runs all n requests at once; returns when all are answered or after
// timeout_ms (the late ones get SNK_E_TIMEOUT).
void snk_http_batch(snk_req_t **r, int n, int timeout_ms);
