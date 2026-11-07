# Robot language front end: lexer and the progressive multipass parser of
# crystal-robots (Jason Kridner, GPL-2.0; src/compiler/parser.cr there,
# design in its docs/PARSER.md), rewritten without Regex, String, Array or
# exceptions so it runs under --prelude=empty on the badge.
#
# Same algorithm, same language: pass 0 turns the source into a string of
# token kinds; every later pass applies the FIRST grammar rule (in GRAMMAR
# order) that matches anywhere, to every non-overlapping match, left to
# right, each match collapsing to one new node. Upstream writes each rule as
# a regex over one Unicode glyph per kind; here each rule is a hand-written
# matcher over the Int32 kinds of the current layer, with the same
# lookbehind/lookahead guards. Parsing ends when no rule matches; success is
# a single PROGRAM node. Rule order and guards follow upstream exactly, so
# both accept the same programs and build the same tree (checked against
# upstream by test/robots_spec.cr).
#
# Memory: one shared workspace (game_alloc, PSRAM on the badge), reused for
# every parse. Nodes 0..ntok-1 are the tokens (a = source offset, b =
# length); later nodes are reductions (a = start in the child pool, b =
# child count).

module RL
  # ---- token / glyph kinds ------------------------------------------------
  STRING = 1
  NUMBER = 2
  IDENT  = 3
  NL     = 4
  COMMA  = 5
  LP     = 6
  RP     = 7
  ASSIGN = 8
  ADDA   = 9
  SUBA   = 10
  MULA   = 11
  MODA   = 12
  ADD    = 13
  SUB    = 14
  MUL    = 15
  FDIV   = 16
  DIV    = 17
  MOD    = 18
  EQ     = 19
  NE     = 20
  GT     = 21
  LT     = 22
  GE     = 23
  LE     = 24
  AND    = 25
  OR     = 26
  XOR    = 27
  # keywords
  K_BEGIN   = 28
  K_BREAK   = 29
  K_CASE    = 30
  K_DEF     = 31
  K_DO      = 32
  K_ELSE    = 33
  K_ELSIF   = 34
  K_END     = 35
  K_FALSE   = 36
  K_FOR     = 37
  K_IF      = 38
  K_IN      = 39
  K_NEXT    = 40
  K_NIL     = 41
  K_REQUIRE = 42
  K_THEN    = 43
  K_TRUE    = 44
  K_WHILE   = 45
  K_UNTIL   = 46
  K_WHEN    = 47
  K_RETURN  = 48
  K_MAIN    = 49
  K_GLOBAL  = 50
  M0        = 51 # damage speed loc_x loc_y sleep
  M1        = 52 # puts rand sqrt sin cos tan atan
  M2        = 53 # scan cannon drive
  EXPR      = 54
  IF_HEAD    = 55
  ELSIF_HEAD = 56
  WHILE_HEAD = 57
  UNTIL_HEAD = 58
  CASE_HEAD  = 59
  WHEN_HEAD  = 60
  DEF_HEAD   = 61
  MAIN_HEAD  = 62
  STMT       = 63
  PROGRAM    = 64
  NKINDS     = 65

  # ---- grammar rules, in priority order (0 = lexer) -------------------------
  R_LEX        = 0
  R_MAIN_HEAD  = 1
  R_DEF_HEAD   = 2
  R_GLOBAL     = 3
  R_LITERAL    = 4
  R_CALL0      = 5
  R_CALL       = 6
  R_CALL1      = 7
  R_CALL2      = 8
  R_PAREN      = 9
  R_NEG        = 10
  R_MUL        = 11
  R_ADD        = 12
  R_CMP        = 13
  R_EQ         = 14
  R_AND        = 15
  R_OR         = 16
  R_COMMAND1   = 17
  R_COMMAND2   = 18
  R_ASSIGN     = 19
  R_OPASSIGN   = 20
  R_IF_HEAD    = 21
  R_ELSIF_HEAD = 22
  R_WHILE_HEAD = 23
  R_UNTIL_HEAD = 24
  R_CASE_HEAD  = 25
  R_WHEN_HEAD  = 26
  R_RETURN     = 27
  R_BREAK      = 28
  R_EXPRSTMT   = 29
  R_IF         = 30
  R_WHILE      = 31
  R_UNTIL      = 32
  R_CASE       = 33
  R_DEF        = 34
  R_MAIN       = 35
  R_PROGRAM    = 36
  NRULES       = 37

  # ---- limits ---------------------------------------------------------------
  SRC_MAX    = 16384 # bytes of robot source
  TOK_MAX    = 4096
  NODE_MAX   = 3 * TOK_MAX + 8
  MAX_PASSES = 20_000     # upstream Parser.max_passes
  MAX_GLYPHS = 2_000_000  # upstream Parser.max_glyphs
  ERR_MAX    = 160

  @@ready = false
  @@src = Pointer(UInt8).null
  @@len = 0
  @@nt = Pointer(Int32).null # node kind
  @@nr = Pointer(Int32).null # node rule
  @@na = Pointer(Int32).null
  @@nb = Pointer(Int32).null
  @@nn = 0
  @@ntok = 0
  @@cur = Pointer(Int32).null
  @@nxt = Pointer(Int32).null
  @@cn = 0
  @@pool = Pointer(Int32).null
  @@pn = 0
  @@passes = 0
  @@emitted = 0
  @@pass_rule = Pointer(Int32).null # rule of each pass (the derivation)
  @@pass_size = Pointer(Int32).null # glyphs in each pass
  @@err = Pointer(UInt8).null
  @@errlen = 0
  @@err_off = 0 # source offset the error points at, -1 none

  def self.setup : Bool
    return true if @@ready
    @@src = game_alloc(SRC_MAX &+ 1)
    @@nt = game_alloc(NODE_MAX &* 4).as(Int32*)
    @@nr = game_alloc(NODE_MAX &* 4).as(Int32*)
    @@na = game_alloc(NODE_MAX &* 4).as(Int32*)
    @@nb = game_alloc(NODE_MAX &* 4).as(Int32*)
    @@cur = game_alloc(TOK_MAX &* 4).as(Int32*)
    @@nxt = game_alloc(TOK_MAX &* 4).as(Int32*)
    @@pool = game_alloc(NODE_MAX &* 4).as(Int32*)
    @@pass_rule = game_alloc((MAX_PASSES &+ 2) &* 4).as(Int32*)
    @@pass_size = game_alloc((MAX_PASSES &+ 2) &* 4).as(Int32*)
    @@err = game_alloc(ERR_MAX &+ 1)
    return false if @@src.null? || @@nt.null? || @@nr.null? || @@na.null? || @@nb.null? ||
                    @@cur.null? || @@nxt.null? || @@pool.null? || @@pass_rule.null? ||
                    @@pass_size.null? || @@err.null?
    @@ready = true
  end

  # ---- accessors ------------------------------------------------------------
  def self.src : UInt8*
    @@src
  end

  def self.src_len : Int32
    @@len
  end

  def self.kind(i : Int32) : Int32
    @@nt[i]
  end

  def self.rule(i : Int32) : Int32
    @@nr[i]
  end

  def self.leaf?(i : Int32) : Bool
    @@nr[i] == R_LEX
  end

  # Leaf: source offset and length.
  def self.start(i : Int32) : Int32
    @@na[i]
  end

  def self.length(i : Int32) : Int32
    @@nb[i]
  end

  # Reduction: children.
  def self.nkids(i : Int32) : Int32
    leaf?(i) ? 0 : @@nb[i]
  end

  def self.kid(i : Int32, k : Int32) : Int32
    @@pool[@@na[i] &+ k]
  end

  def self.nodes : Int32
    @@nn
  end

  def self.tokens : Int32
    @@ntok
  end

  def self.passes : Int32
    @@passes
  end

  def self.pass_rule(k : Int32) : Int32
    @@pass_rule[k]
  end

  def self.pass_size(k : Int32) : Int32
    @@pass_size[k]
  end

  def self.root : Int32
    @@cur[0]
  end

  def self.error : UInt8*
    @@err
  end

  def self.error_len : Int32
    @@errlen
  end

  def self.error_offset : Int32
    @@err_off
  end

  # First leaf under node i (its source offset is where i begins).
  def self.first_leaf(i : Int32) : Int32
    while !leaf?(i)
      return i if @@nb[i] == 0
      i = kid(i, 0)
    end
    i
  end

  def self.origin(i : Int32) : Int32
    l = first_leaf(i)
    leaf?(l) ? @@na[l] : 0
  end

  # 1-based line of a source offset.
  def self.line_of(off : Int32) : Int32
    line = 1
    j = 0
    while j < off && j < @@len
      line = line &+ 1 if @@src[j] == 0x0A_u8
      j = j &+ 1
    end
    line
  end

  # 1-based column of a source offset (upstream: offset - last newline).
  def self.col_of(off : Int32) : Int32
    j = off &- 1
    while j >= 0 && @@src[j] != 0x0A_u8
      j = j &- 1
    end
    off &- j
  end

  # Same bytes as w?
  def self.word?(p : UInt8*, n : Int32, w : String) : Bool
    return false if n != w.bytesize
    q = w.to_unsafe
    i = 0
    while i < n
      return false if p[i] != q[i]
      i = i &+ 1
    end
    true
  end

  # Leaf text equals w?
  def self.leaf_is?(i : Int32, w : String) : Bool
    word?(@@src + @@na[i].to_i64!, @@nb[i], w)
  end

  # Two leaves with the same text?
  def self.same_text?(i : Int32, j : Int32) : Bool
    n = @@nb[i]
    return false if n != @@nb[j]
    a = @@na[i]
    b = @@na[j]
    k = 0
    while k < n
      return false if @@src[a &+ k] != @@src[b &+ k]
      k = k &+ 1
    end
    true
  end

  # ---- error messages -------------------------------------------------------
  def self.err_clear : Nil
    @@errlen = 0
    @@err_off = -1
    @@err[0] = 0_u8
  end

  def self.err_byte(c : UInt8) : Nil
    if @@errlen < ERR_MAX
      @@err[@@errlen] = c
      @@errlen = @@errlen &+ 1
      @@err[@@errlen] = 0_u8
    end
  end

  def self.err_s(s : String) : Nil
    p = s.to_unsafe
    i = 0
    while i < s.bytesize
      err_byte(p[i])
      i = i &+ 1
    end
  end

  def self.err_bytes(p : UInt8*, n : Int32) : Nil
    i = 0
    while i < n
      err_byte(p[i])
      i = i &+ 1
    end
  end

  def self.err_int(v : Int32) : Nil
    if v < 0
      err_byte(0x2D_u8)
      v = 0 &- v
    end
    d = 1
    while v.unsafe_div(d) >= 10
      d = d &* 10
    end
    while d > 0
      err_byte((0x30 &+ v.unsafe_div(d).unsafe_mod(10)).to_u8!)
      d = d.unsafe_div(10)
    end
  end

  # " at line:col"
  def self.err_at(off : Int32) : Nil
    @@err_off = off
    err_s(" at ")
    err_int(line_of(off))
    err_byte(0x3A_u8)
    err_int(col_of(off))
  end

  # ---- lexer (pass 0) -------------------------------------------------------
  def self.push(kind : Int32, rule : Int32, a : Int32, b : Int32) : Int32
    i = @@nn
    @@nt[i] = kind
    @@nr[i] = rule
    @@na[i] = a
    @@nb[i] = b
    @@nn = i &+ 1
    i
  end

  def self.alpha?(c : UInt8) : Bool
    (c >= 0x41_u8 && c <= 0x5A_u8) || (c >= 0x61_u8 && c <= 0x7A_u8) || c == 0x5F_u8
  end

  def self.digit?(c : UInt8) : Bool
    c >= 0x30_u8 && c <= 0x39_u8
  end

  # Keyword / builtin kind of an identifier, or IDENT.
  def self.word_kind(p : UInt8*, n : Int32) : Int32
    return K_BEGIN if word?(p, n, "begin")
    return K_BREAK if word?(p, n, "break")
    return K_CASE if word?(p, n, "case")
    return K_DEF if word?(p, n, "def")
    return K_DO if word?(p, n, "do")
    return K_ELSE if word?(p, n, "else")
    return K_ELSIF if word?(p, n, "elsif")
    return K_END if word?(p, n, "end")
    return K_FALSE if word?(p, n, "false")
    return K_FOR if word?(p, n, "for")
    return K_IF if word?(p, n, "if")
    return K_IN if word?(p, n, "in")
    return K_NEXT if word?(p, n, "next")
    return K_NIL if word?(p, n, "nil")
    return K_REQUIRE if word?(p, n, "require")
    return K_THEN if word?(p, n, "then")
    return K_TRUE if word?(p, n, "true")
    return K_WHILE if word?(p, n, "while")
    return K_UNTIL if word?(p, n, "until")
    return K_WHEN if word?(p, n, "when")
    return K_RETURN if word?(p, n, "return")
    return K_MAIN if word?(p, n, "main")
    return K_GLOBAL if word?(p, n, "global")
    return M0 if word?(p, n, "damage") || word?(p, n, "speed") || word?(p, n, "loc_x") ||
                 word?(p, n, "loc_y") || word?(p, n, "sleep")
    return M1 if word?(p, n, "puts") || word?(p, n, "rand") || word?(p, n, "sqrt") ||
                 word?(p, n, "sin") || word?(p, n, "cos") || word?(p, n, "tan") || word?(p, n, "atan")
    return M2 if word?(p, n, "scan") || word?(p, n, "cannon") || word?(p, n, "drive")
    IDENT
  end

  # Operator at p (n bytes left): kind << 8 | length, or 0.
  def self.operator(p : UInt8*, n : Int32) : Int32
    c = p[0]
    d = n > 1 ? p[1] : 0_u8
    if d == 0x3D_u8 # '='
      return EQ.unsafe_shl(8) | 2 if c == 0x3D_u8
      return NE.unsafe_shl(8) | 2 if c == 0x21_u8
      return LE.unsafe_shl(8) | 2 if c == 0x3C_u8
      return GE.unsafe_shl(8) | 2 if c == 0x3E_u8
      return ADDA.unsafe_shl(8) | 2 if c == 0x2B_u8
      return SUBA.unsafe_shl(8) | 2 if c == 0x2D_u8
      return MULA.unsafe_shl(8) | 2 if c == 0x2A_u8
      return MODA.unsafe_shl(8) | 2 if c == 0x25_u8
    end
    return AND.unsafe_shl(8) | 2 if c == 0x26_u8 && d == 0x26_u8
    return OR.unsafe_shl(8) | 2 if c == 0x7C_u8 && d == 0x7C_u8
    return FDIV.unsafe_shl(8) | 2 if c == 0x2F_u8 && d == 0x2F_u8
    return SUB.unsafe_shl(8) | 1 if c == 0x2D_u8
    return ADD.unsafe_shl(8) | 1 if c == 0x2B_u8
    return MUL.unsafe_shl(8) | 1 if c == 0x2A_u8
    return DIV.unsafe_shl(8) | 1 if c == 0x2F_u8
    return MOD.unsafe_shl(8) | 1 if c == 0x25_u8
    return LT.unsafe_shl(8) | 1 if c == 0x3C_u8
    return GT.unsafe_shl(8) | 1 if c == 0x3E_u8
    return ASSIGN.unsafe_shl(8) | 1 if c == 0x3D_u8
    return AND.unsafe_shl(8) | 1 if c == 0x26_u8
    return OR.unsafe_shl(8) | 1 if c == 0x7C_u8
    return XOR.unsafe_shl(8) | 1 if c == 0x5E_u8
    return LP.unsafe_shl(8) | 1 if c == 0x28_u8
    return RP.unsafe_shl(8) | 1 if c == 0x29_u8
    return COMMA.unsafe_shl(8) | 1 if c == 0x2C_u8
    0
  end

  def self.lex_tok(kind : Int32, pos : Int32, len : Int32) : Bool
    if kind == NL && (@@cn == 0 || @@nt[@@cur[@@cn &- 1]] == NL)
      return true
    end
    if @@cn >= TOK_MAX &- 1
      err_s("Program has too many tokens (more than ")
      err_int(TOK_MAX &- 1)
      err_byte(0x29_u8)
      err_at(pos)
      return false
    end
    @@cur[@@cn] = push(kind, R_LEX, pos, len)
    @@cn = @@cn &+ 1
    true
  end

  def self.lex : Bool
    pos = 0
    n = @@len
    s = @@src
    while pos < n
      c = s[pos]
      if c == 0x23_u8 # '#' comment to end of line
        while pos < n && s[pos] != 0x0A_u8
          pos = pos &+ 1
        end
      elsif c == 0x20_u8 || c == 0x09_u8 || c == 0x0D_u8
        pos = pos &+ 1
      elsif c == 0x0A_u8 || c == 0x3B_u8
        b = pos
        while pos < n && (s[pos] == 0x0A_u8 || s[pos] == 0x3B_u8)
          pos = pos &+ 1
        end
        return false unless lex_tok(NL, b, pos &- b)
      elsif c == 0x22_u8 && closing_quote(pos) >= 0
        e = closing_quote(pos)
        return false unless lex_tok(STRING, pos, e &+ 1 &- pos)
        pos = e &+ 1
      elsif digit?(c)
        b = pos
        while pos < n && digit?(s[pos])
          pos = pos &+ 1
        end
        return false unless lex_tok(NUMBER, b, pos &- b)
      elsif (op = operator(s + pos.to_i64!, n &- pos)) != 0
        len = op & 0xFF
        return false unless lex_tok(op.unsafe_shr(8), pos, len)
        pos = pos &+ len
      elsif alpha?(c)
        b = pos
        while pos < n && (alpha?(s[pos]) || digit?(s[pos]))
          pos = pos &+ 1
        end
        return false unless lex_tok(word_kind(s + b.to_i64!, pos &- b), b, pos &- b)
      else
        err_s("Unexpected character ")
        if c >= 0x20_u8 && c < 0x7F_u8
          err_byte(0x27_u8)
          err_byte(c)
          err_byte(0x27_u8)
        else
          err_s("0x")
          err_byte(hex(c.unsafe_shr(4)))
          err_byte(hex(c & 0xF_u8))
        end
        err_at(pos)
        return false
      end
    end
    # end of input terminates the last statement
    if @@cn > 0 && @@nt[@@cur[@@cn &- 1]] != NL
      return false unless lex_tok(NL, n, 0)
    end
    @@ntok = @@nn
    true
  end

  def self.hex(v : UInt8) : UInt8
    v < 10_u8 ? 0x30_u8 &+ v : 0x37_u8 &+ v
  end

  # Offset of the '"' closing the string opened at pos, or -1.
  def self.closing_quote(pos : Int32) : Int32
    j = pos &+ 1
    while j < @@len
      return j if @@src[j] == 0x22_u8
      j = j &+ 1
    end
    -1
  end

  # ---- grammar matchers -----------------------------------------------------
  # Kind of glyph i of the current layer, -1 outside it.
  def self.g(i : Int32) : Int32
    i >= 0 && i < @@cn ? @@nt[@@cur[i]] : -1
  end

  def self.value?(t : Int32) : Bool
    t == NUMBER || t == STRING || t == EXPR || t == IDENT
  end

  # Infix precedence level: 1 mul .. 6 or, 0 not an infix operator.
  def self.level(t : Int32) : Int32
    return 1 if t == MUL || t == DIV || t == FDIV || t == MOD
    return 2 if t == ADD || t == SUB
    return 3 if t == LT || t == GT || t == LE || t == GE
    return 4 if t == EQ || t == NE
    return 5 if t == AND
    return 6 if t == OR || t == XOR
    0
  end

  # `(?=[⏎⟯，])`
  def self.closer?(t : Int32) : Bool
    t == NL || t == RP || t == COMMA
  end

  def self.opassign?(t : Int32) : Bool
    t == ADDA || t == SUBA || t == MULA || t == MODA
  end

  # Statements from j on; returns the first index that is not one.
  def self.stmts(j : Int32) : Int32
    while g(j) == STMT
      j = j &+ 1
    end
    j
  end

  # `x(V(,V)*)?y` starting at j (on the opening kind); end index or -1.
  def self.arg_list(j : Int32, close : Int32) : Int32
    j = j &+ 1
    return j &+ 1 if g(j) == close
    return -1 unless value?(g(j))
    j = j &+ 1
    while g(j) == COMMA && value?(g(j &+ 1))
      j = j &+ 2
    end
    g(j) == close ? j &+ 1 : -1
  end

  # Length of rule r's match at glyph i of the current layer, 0 if none.
  def self.match(r : Int32, i : Int32) : Int32
    t = g(i)
    if r == R_MAIN_HEAD # 🏁⟮🐍⟯🔖⏎
      return 6 if t == K_MAIN && g(i &+ 1) == LP && g(i &+ 2) == STRING && g(i &+ 3) == RP &&
                  g(i &+ 4) == K_DO && g(i &+ 5) == NL
    elsif r == R_DEF_HEAD # 🔕𝑥(⟮(𝑥(，𝑥)*)?⟯)?⏎
      return 0 unless t == K_DEF && g(i &+ 1) == IDENT
      j = i &+ 2
      if g(j) == LP
        k = j &+ 1
        if g(k) == IDENT
          k = k &+ 1
          while g(k) == COMMA && g(k &+ 1) == IDENT
            k = k &+ 2
          end
        end
        j = k &+ 1 if g(k) == RP
      end
      return j &+ 1 &- i if g(j) == NL
    elsif r == R_GLOBAL # 🌐⟮𝑥，V⟯⏎
      return 7 if t == K_GLOBAL && g(i &+ 1) == LP && g(i &+ 2) == IDENT && g(i &+ 3) == COMMA &&
                  value?(g(i &+ 4)) && g(i &+ 5) == RP && g(i &+ 6) == NL
    elsif r == R_LITERAL
      return 1 if t == K_TRUE || t == K_FALSE
    elsif r == R_CALL0
      return 1 if t == M0
    elsif r == R_CALL # 𝑥⟮(V(，V)*)?⟯
      if t == IDENT && g(i &+ 1) == LP
        e = arg_list(i &+ 1, RP)
        return e &- i if e > 0
      end
    elsif r == R_CALL1 # ∊⟮V⟯
      return 4 if t == M1 && g(i &+ 1) == LP && value?(g(i &+ 2)) && g(i &+ 3) == RP
    elsif r == R_CALL2 # ∋⟮V，V⟯
      return 6 if t == M2 && g(i &+ 1) == LP && value?(g(i &+ 2)) && g(i &+ 3) == COMMA &&
                  value?(g(i &+ 4)) && g(i &+ 5) == RP
    elsif r == R_PAREN # ⟮V⟯
      return 3 if t == LP && value?(g(i &+ 1)) && g(i &+ 2) == RP
    elsif r == R_NEG # (?<![№🐍😑𝑥⟯])⊖V
      b = g(i &- 1)
      return 2 if t == SUB && !value?(b) && b != RP && value?(g(i &+ 1))
    elsif r >= R_MUL && r <= R_OR
      lv = r &- R_MUL &+ 1
      return 0 unless value?(t) && level(g(i &+ 1)) == lv && value?(g(i &+ 2))
      b = level(g(i &- 1))
      return 0 if b != 0 && b <= lv
      a = level(g(i &+ 3))
      return 0 if a != 0 && a < lv
      return 3
    elsif r == R_COMMAND1 # ∊V(?=[⏎⟯，])
      return 2 if t == M1 && value?(g(i &+ 1)) && closer?(g(i &+ 2))
    elsif r == R_COMMAND2 # ∋V，V(?=[⏎⟯，])
      return 4 if t == M2 && value?(g(i &+ 1)) && g(i &+ 2) == COMMA && value?(g(i &+ 3)) &&
                  closer?(g(i &+ 4))
    elsif r == R_ASSIGN # 𝑥＝V(?=[⏎⟯，])
      return 3 if t == IDENT && g(i &+ 1) == ASSIGN && value?(g(i &+ 2)) && closer?(g(i &+ 3))
    elsif r == R_OPASSIGN
      return 3 if t == IDENT && opassign?(g(i &+ 1)) && value?(g(i &+ 2)) && closer?(g(i &+ 3))
    elsif r >= R_IF_HEAD && r <= R_WHEN_HEAD # 🔜V⏎ ...
      kw = r == R_IF_HEAD ? K_IF : (r == R_ELSIF_HEAD ? K_ELSIF : (r == R_WHILE_HEAD ? K_WHILE :
           (r == R_UNTIL_HEAD ? K_UNTIL : (r == R_CASE_HEAD ? K_CASE : K_WHEN))))
      return 3 if t == kw && value?(g(i &+ 1)) && g(i &+ 2) == NL
    elsif r == R_RETURN # ↩V?⏎
      if t == K_RETURN
        return 3 if value?(g(i &+ 1)) && g(i &+ 2) == NL
        return 2 if g(i &+ 1) == NL
      end
    elsif r == R_BREAK
      return 2 if t == K_BREAK && g(i &+ 1) == NL
    elsif r == R_EXPRSTMT
      return 2 if value?(t) && g(i &+ 1) == NL
    elsif r == R_IF # 🅸❢*(🅴❢*)*(🔗⏎❢*)?🔙⏎
      return 0 unless t == IF_HEAD
      j = stmts(i &+ 1)
      while g(j) == ELSIF_HEAD
        j = stmts(j &+ 1)
      end
      j = stmts(j &+ 2) if g(j) == K_ELSE && g(j &+ 1) == NL
      return j &+ 2 &- i if g(j) == K_END && g(j &+ 1) == NL
    elsif r == R_WHILE || r == R_UNTIL || r == R_DEF || r == R_MAIN # 🆆❢*🔙⏎
      head = r == R_WHILE ? WHILE_HEAD : (r == R_UNTIL ? UNTIL_HEAD : (r == R_DEF ? DEF_HEAD : MAIN_HEAD))
      return 0 unless t == head
      j = stmts(i &+ 1)
      return j &+ 2 &- i if g(j) == K_END && g(j &+ 1) == NL
    elsif r == R_CASE # 🅲(🆂❢*)+(🔗⏎❢*)?🔙⏎
      return 0 unless t == CASE_HEAD && g(i &+ 1) == WHEN_HEAD
      j = i &+ 1
      while g(j) == WHEN_HEAD
        j = stmts(j &+ 1)
      end
      j = stmts(j &+ 2) if g(j) == K_ELSE && g(j &+ 1) == NL
      return j &+ 2 &- i if g(j) == K_END && g(j &+ 1) == NL
    elsif r == R_PROGRAM # \A❢+\z
      return @@cn if i == 0 && stmts(0) == @@cn
    end
    0
  end

  def self.rule_kind(r : Int32) : Int32
    return MAIN_HEAD if r == R_MAIN_HEAD
    return DEF_HEAD if r == R_DEF_HEAD
    return STMT if r == R_GLOBAL
    return EXPR if r <= R_OPASSIGN
    return IF_HEAD if r == R_IF_HEAD
    return ELSIF_HEAD if r == R_ELSIF_HEAD
    return WHILE_HEAD if r == R_WHILE_HEAD
    return UNTIL_HEAD if r == R_UNTIL_HEAD
    return CASE_HEAD if r == R_CASE_HEAD
    return WHEN_HEAD if r == R_WHEN_HEAD
    return PROGRAM if r == R_PROGRAM
    STMT
  end

  def self.record_pass(r : Int32) : Nil
    if @@passes <= MAX_PASSES
      @@pass_rule[@@passes] = r
      @@pass_size[@@passes] = @@cn
    end
    @@passes = @@passes &+ 1
    @@emitted = @@emitted &+ @@cn
  end

  # Apply rule r to every non-overlapping match; false when none.
  def self.apply(r : Int32) : Bool
    n = @@cn
    i = 0
    m = 0
    while i < n
      m = match(r, i)
      break if m > 0
      i = i &+ 1
    end
    return false if i >= n
    k = 0
    while k < i
      @@nxt[k] = @@cur[k]
      k = k &+ 1
    end
    kind = rule_kind(r)
    while i < n
      m = match(r, i) if m == 0
      if m > 0
        pstart = @@pn
        j = 0
        while j < m
          @@pool[@@pn] = @@cur[i &+ j]
          @@pn = @@pn &+ 1
          j = j &+ 1
        end
        @@nxt[k] = push(kind, r, pstart, m)
        k = k &+ 1
        i = i &+ m
        m = 0
      else
        @@nxt[k] = @@cur[i]
        k = k &+ 1
        i = i &+ 1
      end
    end
    t = @@cur
    @@cur = @@nxt
    @@nxt = t
    @@cn = k
    record_pass(r)
    true
  end

  def self.reduce_once : Bool
    r = 1
    while r < NRULES
      return true if apply(r)
      r = r &+ 1
    end
    false
  end

  def self.parsed? : Bool
    @@cn == 1 && @@nt[@@cur[0]] == PROGRAM
  end

  # Parse src[0, n]. False with error/error_offset set on failure.
  def self.parse(p : UInt8*, n : Int32) : Bool
    return false unless setup
    err_clear
    @@nn = 0
    @@cn = 0
    @@pn = 0
    @@passes = 0
    @@emitted = 0
    @@ntok = 0
    if n > SRC_MAX
      err_s("Program is too long (more than ")
      err_int(SRC_MAX)
      err_s(" bytes)")
      return false
    end
    i = 0
    while i < n
      @@src[i] = p[i]
      i = i &+ 1
    end
    @@src[n] = 0_u8
    @@len = n
    return false unless lex
    record_pass(R_LEX)
    if @@cn == 0 # an empty source is an empty program
      @@cur[0] = push(PROGRAM, R_PROGRAM, @@pn, 0)
      @@cn = 1
      record_pass(R_PROGRAM)
      return true
    end
    while reduce_once
      if @@passes > MAX_PASSES
        err_s("Program needs more than ")
        err_int(MAX_PASSES)
        err_s(" passes")
        err_at(origin(@@nn &- 1))
        return false
      end
      if @@emitted > MAX_GLYPHS
        err_s("Program is too large to parse (more than ")
        err_int(MAX_GLYPHS)
        err_s(" glyphs of work)")
        err_at(origin(@@nn &- 1))
        return false
      end
      if @@nn >= NODE_MAX &- TOK_MAX
        err_s("Program is too large to parse")
        err_at(origin(@@nn &- 1))
        return false
      end
    end
    return true if parsed?
    bad = @@cur[0]
    j = 0
    while j < @@cn
      if @@nt[@@cur[j]] != STMT
        bad = @@cur[j]
        break
      end
      j = j &+ 1
    end
    err_s("Cannot reduce ")
    err_s(kind_name(@@nt[bad]))
    err_at(origin(bad))
    false
  end

  # Upstream's Type names, for messages.
  def self.kind_name(t : Int32) : String
    return "String" if t == STRING
    return "Number" if t == NUMBER
    return "Identifier" if t == IDENT
    return "Newline" if t == NL
    return "Comma" if t == COMMA
    return "OpenParen" if t == LP
    return "CloseParen" if t == RP
    return "Assign" if t >= ASSIGN && t <= MODA
    return "Operator" if t >= ADD && t <= XOR
    return "EndKeyword" if t == K_END
    return "ElseKeyword" if t == K_ELSE
    return "Keyword" if t >= K_BEGIN && t <= K_GLOBAL
    return "Method" if t >= M0 && t <= M2
    return "Expression" if t == EXPR
    return "IfHead" if t == IF_HEAD
    return "ElsifHead" if t == ELSIF_HEAD
    return "WhileHead" if t == WHILE_HEAD
    return "UntilHead" if t == UNTIL_HEAD
    return "CaseHead" if t == CASE_HEAD
    return "WhenHead" if t == WHEN_HEAD
    return "DefHead" if t == DEF_HEAD
    return "MainHead" if t == MAIN_HEAD
    return "Statement" if t == STMT
    return "Program" if t == PROGRAM
    "Invalid"
  end
end
