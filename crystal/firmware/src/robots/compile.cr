# Robot language back end: crystal-robots' Checker (src/compiler/checker.cr)
# and a compiler from the RL parse tree to a compact bytecode for the
# resumable VM in src/robots/battle.cr. Prelude-free, fixed per-robot
# buffers (game_alloc).
#
# The bytecode reproduces upstream's stepwise interpreter
# (src/battle/step_robot.cr) cycle for cycle: every CROBOTS charge
# (fetch/operator/store 1, builtin 2, call 3, branch 1, statement 1) is an
# explicit TICK that ends the robot's step, and every host call or check
# sits on the same side of its TICKs as upstream, so builtins act on the
# battlefield in the same cycle and runtime errors restart `main` in the
# same cycle as upstream does.

require "./lang"

module RC
  MAX_ROBOTS = 4
  CHECK_SLOT = MAX_ROBOTS # an extra program slot for checking uploads
  SLOTS      = MAX_ROBOTS + 1
  # Deepest parse tree accepted. The checker and the compiler recurse once
  # per tree level, and they also run on the shell and HTTP tasks (small
  # stacks). Real robots stay far below this (upstream examples: <= 13,
  # test/robots/depth.cr).
  MAX_DEPTH = 48
  CODE_MAX   = 16384
  SYM_MAX    = 1024
  NAME_MAX   = 24

  # ---- opcodes ----------------------------------------------------------------
  OP_PUSH     =  1 # v
  OP_PUSHS    =  2 # start, len (a string literal's contents in the source)
  OP_TICK     =  3 # n: charge n cycles, the first one ends this step
  OP_LOAD     =  4 # sym, slot, mode
  OP_STORE    =  5 # sym, slot, mode (value stays)
  OP_OPASSIGN =  6 # op, sym, slot, mode
  OP_BINOP    =  7 # op
  OP_NEG      =  8
  OP_POPN     =  9 # n
  OP_SETLAST  = 10 # pop into the frame's last statement value
  OP_LAST0    = 11
  OP_JMP      = 12 # addr
  OP_JF       = 13 # addr: pop, jump if falsy
  OP_JT       = 14 # addr: pop, jump if truthy
  OP_CASEEQ   = 15 # pop a when value, push subject == it
  OP_CALL     = 16 # sym, argc
  OP_BUILTIN  = 17 # id
  OP_RET      = 18 # pop the return value
  OP_RETLAST  = 19 # return the frame's last statement value
  OP_SETGLOBAL = 20 # sym
  OP_SETCONST = 21 # sym
  OP_CFRAME   = 22 # enter the constants frame (top-level statement)
  OP_CFRAME_END = 23
  OP_ENDINIT  = 24 # top level done: start main
  OP_END      = 25 # main finished
  OP_FAIL     = 26 # what: runtime error (1 = cannot execute main)

  # LOAD/STORE modes: where a name lives besides globals/constants.
  MODE_FRAME = 0 # a def or main frame: local slots
  MODE_CONST = 1 # top-level statement: the constants are the frame
  MODE_NONE  = 2 # global / constant initialiser: no frame at all

  # Builtins.
  B_PUTS   =  1
  B_RAND   =  2
  B_SQRT   =  3
  B_SIN    =  4
  B_COS    =  5
  B_TAN    =  6
  B_ATAN   =  7
  B_SCAN   =  8
  B_CANNON =  9
  B_DRIVE  = 10
  B_DAMAGE = 11
  B_SPEED  = 12
  B_LOC_X  = 13
  B_LOC_Y  = 14
  B_SLEEP  = 15

  @@ready = false
  # per robot (index r * size)
  @@code = Pointer(Int32).null
  @@code_len = Pointer(Int32).null
  @@src = Pointer(UInt8).null
  @@src_len = Pointer(Int32).null
  @@nsym = Pointer(Int32).null
  @@sym_start = Pointer(Int32).null
  @@sym_len = Pointer(Int32).null
  @@fn_entry = Pointer(Int32).null
  @@fn_arity = Pointer(Int32).null
  @@fn_slots = Pointer(Int32).null
  @@init_entry = Pointer(Int32).null
  @@main_entry = Pointer(Int32).null
  @@main_slots = Pointer(Int32).null
  @@name = Pointer(UInt8).null
  @@name_len = Pointer(Int32).null
  # compile-time scratch
  @@tok_sym = Pointer(Int32).null # leaf node -> sym, -1
  @@depth = Pointer(Int32).null   # tree depth below each node
  @@slot_of = Pointer(Int32).null # sym -> slot in the function being compiled
  @@slot_epoch = Pointer(Int32).null
  @@epoch = 0
  @@nslots = 0
  @@set_g = Pointer(UInt8).null # checker sets, per sym
  @@set_c = Pointer(UInt8).null
  @@set_l = Pointer(UInt8).null
  @@fn_chk = Pointer(Int32).null # sym -> arity, -1
  @@problems = 0
  @@r = 0
  @@pc = 0
  @@cbase = 0
  @@sbase = 0
  @@overflow = false
  @@loop_cases = 0 # case subjects pushed since the innermost loop began
  @@loop_exit = -1 # patch list head for breaks of the innermost loop
  @@mode = 0

  def self.setup : Bool
    return true if @@ready
    return false unless RL.setup
    n = SLOTS
    @@code = game_alloc(n &* CODE_MAX &* 4).as(Int32*)
    @@code_len = game_alloc(n &* 4).as(Int32*)
    @@src = game_alloc(n &* (RL::SRC_MAX &+ 1))
    @@src_len = game_alloc(n &* 4).as(Int32*)
    @@nsym = game_alloc(n &* 4).as(Int32*)
    @@sym_start = game_alloc(n &* SYM_MAX &* 4).as(Int32*)
    @@sym_len = game_alloc(n &* SYM_MAX &* 4).as(Int32*)
    @@fn_entry = game_alloc(n &* SYM_MAX &* 4).as(Int32*)
    @@fn_arity = game_alloc(n &* SYM_MAX &* 4).as(Int32*)
    @@fn_slots = game_alloc(n &* SYM_MAX &* 4).as(Int32*)
    @@init_entry = game_alloc(n &* 4).as(Int32*)
    @@main_entry = game_alloc(n &* 4).as(Int32*)
    @@main_slots = game_alloc(n &* 4).as(Int32*)
    @@name = game_alloc(n &* NAME_MAX)
    @@name_len = game_alloc(n &* 4).as(Int32*)
    @@tok_sym = game_alloc(RL::NODE_MAX &* 4).as(Int32*)
    @@depth = game_alloc(RL::NODE_MAX &* 4).as(Int32*)
    @@slot_of = game_alloc(SYM_MAX &* 4).as(Int32*)
    @@slot_epoch = game_alloc(SYM_MAX &* 4).as(Int32*)
    @@set_g = game_alloc(SYM_MAX)
    @@set_c = game_alloc(SYM_MAX)
    @@set_l = game_alloc(SYM_MAX)
    @@fn_chk = game_alloc(SYM_MAX &* 4).as(Int32*)
    return false if @@code.null? || @@code_len.null? || @@src.null? || @@src_len.null? ||
                    @@nsym.null? || @@sym_start.null? || @@sym_len.null? || @@fn_entry.null? ||
                    @@fn_arity.null? || @@fn_slots.null? || @@init_entry.null? ||
                    @@main_entry.null? || @@main_slots.null? || @@name.null? ||
                    @@name_len.null? || @@tok_sym.null? || @@slot_of.null? ||
                    @@slot_epoch.null? || @@set_g.null? || @@set_c.null? || @@set_l.null? ||
                    @@fn_chk.null? || @@depth.null?
    i = 0 # game_alloc memory is not zeroed on the badge
    while i < SYM_MAX
      @@slot_epoch[i] = 0
      i = i &+ 1
    end
    @@ready = true
  end

  # ---- per-robot accessors (for the VM) --------------------------------------
  def self.code(r : Int32) : Int32*
    @@code + (r &* CODE_MAX).to_i64!
  end

  def self.code_len(r : Int32) : Int32
    @@code_len[r]
  end

  def self.src(r : Int32) : UInt8*
    @@src + (r &* (RL::SRC_MAX &+ 1)).to_i64!
  end

  def self.nsym(r : Int32) : Int32
    @@nsym[r]
  end

  def self.sym_ptr(r : Int32, s : Int32) : UInt8*
    src(r) + @@sym_start[r &* SYM_MAX &+ s].to_i64!
  end

  def self.sym_len(r : Int32, s : Int32) : Int32
    @@sym_len[r &* SYM_MAX &+ s]
  end

  def self.fn_entry(r : Int32, s : Int32) : Int32
    @@fn_entry[r &* SYM_MAX &+ s]
  end

  def self.fn_arity(r : Int32, s : Int32) : Int32
    @@fn_arity[r &* SYM_MAX &+ s]
  end

  def self.fn_slots(r : Int32, s : Int32) : Int32
    @@fn_slots[r &* SYM_MAX &+ s]
  end

  def self.init_entry(r : Int32) : Int32
    @@init_entry[r]
  end

  def self.main_entry(r : Int32) : Int32
    @@main_entry[r]
  end

  def self.main_slots(r : Int32) : Int32
    @@main_slots[r]
  end

  def self.name(r : Int32) : UInt8*
    @@name + (r &* NAME_MAX).to_i64!
  end

  def self.name_len(r : Int32) : Int32
    @@name_len[r]
  end

  # ---- symbols -------------------------------------------------------------------
  def self.intern(leaf : Int32) : Int32
    r = @@r
    n = @@nsym[r]
    p = RL.src + RL.start(leaf).to_i64!
    len = RL.length(leaf)
    s = 0
    while s < n
      if @@sym_len[@@sbase &+ s] == len
        q = src(r) + @@sym_start[@@sbase &+ s].to_i64!
        same = true
        k = 0
        while k < len
          if p[k] != q[k]
            same = false
            break
          end
          k = k &+ 1
        end
        return s if same
      end
      s = s &+ 1
    end
    return -1 if n >= SYM_MAX
    @@sym_start[@@sbase &+ n] = RL.start(leaf)
    @@sym_len[@@sbase &+ n] = len
    @@nsym[r] = n &+ 1
    n
  end

  def self.sym(leaf : Int32) : Int32
    @@tok_sym[leaf]
  end

  def self.err_sym(s : Int32) : Nil
    RL.err_bytes(src(@@r) + @@sym_start[@@sbase &+ s].to_i64!, @@sym_len[@@sbase &+ s])
  end

  # ---- tree helpers ---------------------------------------------------------------
  def self.kids(i : Int32) : Int32
    RL.nkids(i)
  end

  def self.kid(i : Int32, k : Int32) : Int32
    RL.kid(i, k)
  end

  def self.rule(i : Int32) : Int32
    RL.rule(i)
  end

  def self.kind(i : Int32) : Int32
    RL.kind(i)
  end

  # First leaf of node i (an identifier's own leaf, a call's name, ...).
  def self.lexeme(i : Int32) : Int32
    RL.first_leaf(i)
  end

  # k-th identifier child of a def head (0 = the name).
  def self.head_ident(head : Int32, k : Int32) : Int32
    n = kids(head)
    j = 0
    while j < n
      c = kid(head, j)
      if kind(c) == RL::IDENT
        return c if k == 0
        k = k &- 1
      end
      j = j &+ 1
    end
    -1
  end

  def self.head_idents(head : Int32) : Int32
    n = kids(head)
    j = 0
    c = 0
    while j < n
      c = c &+ 1 if kind(kid(head, j)) == RL::IDENT
      j = j &+ 1
    end
    c
  end

  # Argument nodes of a call node: kids from `from` that are not ( ) ,
  def self.arg?(i : Int32) : Bool
    t = kind(i)
    t != RL::LP && t != RL::RP && t != RL::COMMA
  end

  # ---- checker (upstream Checker) ---------------------------------------------------
  def self.problem_start(node : Int32) : Bool
    @@problems = @@problems &+ 1
    return false if @@problems > 1 # only the first one is kept
    RL.err_clear
    true
  end

  def self.problem_end(node : Int32) : Nil
    RL.err_at(RL.origin(node))
  end

  def self.defined_chk?(s : Int32) : Bool
    s >= 0 && (@@set_l[s] != 0 || @@set_g[s] != 0 || @@set_c[s] != 0)
  end

  def self.clear_locals : Nil
    i = 0
    while i < SYM_MAX
      @@set_l[i] = 0_u8
      i = i &+ 1
    end
  end

  def self.check_program : Bool
    @@problems = 0
    i = 0
    while i < SYM_MAX
      @@set_g[i] = 0_u8
      @@set_c[i] = 0_u8
      @@fn_chk[i] = -1
      i = i &+ 1
    end
    root = RL.root
    n = kids(root)
    # declarations first
    j = 0
    while j < n
      st = kid(root, j)
      ru = rule(st)
      if ru == RL::R_DEF
        head = kid(st, 0)
        nm = head_ident(head, 0)
        s = sym(nm)
        if @@fn_chk[s] >= 0
          if problem_start(nm)
            RL.err_s("function ")
            err_sym(s)
            RL.err_s(" is defined twice")
            problem_end(nm)
          end
        end
        @@fn_chk[s] = head_idents(head) &- 1
      elsif ru == RL::R_GLOBAL
        @@set_g[sym(kid(st, 2))] = 1_u8
      elsif ru == RL::R_EXPRSTMT
        e = kid(st, 0)
        @@set_c[sym(lexeme(kid(e, 0)))] = 1_u8 if rule(e) == RL::R_ASSIGN
      end
      j = j &+ 1
    end
    j = 0
    while j < n
      st = kid(root, j)
      ru = rule(st)
      clear_locals
      if ru == RL::R_DEF
        head = kid(st, 0)
        np = head_idents(head)
        k = 1
        while k < np
          @@set_l[sym(head_ident(head, k))] = 1_u8
          k = k &+ 1
        end
        check_body(st, true, false)
      elsif ru == RL::R_GLOBAL
        check_expr(kid(st, 4), false)
      elsif ru == RL::R_MAIN
        check_body(st, false, false)
      else
        check_stmt(st, false, false)
      end
      j = j &+ 1
    end
    @@problems == 0
  end

  # The statement children of a block.
  def self.check_body(block : Int32, in_def : Bool, in_loop : Bool) : Nil
    n = kids(block)
    j = 0
    while j < n
      c = kid(block, j)
      check_stmt(c, in_def, in_loop) if kind(c) == RL::STMT
      j = j &+ 1
    end
  end

  def self.check_stmt(st : Int32, in_def : Bool, in_loop : Bool) : Nil
    ru = rule(st)
    if ru == RL::R_EXPRSTMT
      check_expr(kid(st, 0), in_def)
    elsif ru == RL::R_RETURN
      unless in_def
        if problem_start(st)
          RL.err_s("return outside of a def")
          problem_end(st)
        end
      end
      check_expr(kid(st, 1), in_def) if kids(st) > 2
    elsif ru == RL::R_BREAK
      unless in_loop
        if problem_start(st)
          RL.err_s("break outside of a loop")
          problem_end(st)
        end
      end
    elsif ru == RL::R_IF || ru == RL::R_CASE
      n = kids(st)
      j = 0
      while j < n
        c = kid(st, j)
        t = kind(c)
        if t == RL::IF_HEAD || t == RL::ELSIF_HEAD || t == RL::CASE_HEAD || t == RL::WHEN_HEAD
          check_expr(kid(c, 1), in_def)
        elsif t == RL::STMT
          check_stmt(c, in_def, in_loop)
        end
        j = j &+ 1
      end
    elsif ru == RL::R_WHILE || ru == RL::R_UNTIL
      check_expr(kid(kid(st, 0), 1), in_def)
      check_body(st, in_def, true)
    elsif ru == RL::R_GLOBAL
      @@set_g[sym(kid(st, 2))] = 1_u8
      check_expr(kid(st, 4), in_def)
    elsif ru == RL::R_DEF
      if problem_start(st)
        RL.err_s("def inside a block is not supported")
        problem_end(st)
      end
    end
  end

  def self.check_expr(i : Int32, in_def : Bool) : Nil
    ru = rule(i)
    if ru == RL::R_LEX
      if kind(i) == RL::IDENT
        s = sym(i)
        return if defined_chk?(s)
        ar = @@fn_chk[s]
        if ar >= 0
          if ar != 0 && problem_start(i)
            err_sym(s)
            RL.err_s(" takes ")
            RL.err_int(ar)
            RL.err_s(" arguments but is called with none")
            problem_end(i)
          end
          return
        end
        if problem_start(i)
          RL.err_s("undefined variable or function ")
          err_sym(s)
          problem_end(i)
        end
      end
    elsif ru == RL::R_ASSIGN || ru == RL::R_OPASSIGN
      target = kid(i, 0)
      s = sym(lexeme(target))
      if ru == RL::R_OPASSIGN && !defined_chk?(s)
        if problem_start(target)
          RL.err_s("undefined variable ")
          err_sym(s)
          problem_end(target)
        end
      end
      check_expr(kid(i, 2), in_def)
      @@set_l[s] = 1_u8 unless @@set_g[s] != 0 || @@set_c[s] != 0
    elsif ru == RL::R_CALL
      nm = kid(i, 0)
      s = sym(lexeme(nm))
      n = kids(i)
      argc = 0
      j = 2
      while j < n
        argc = argc &+ 1 if arg?(kid(i, j))
        j = j &+ 1
      end
      ar = @@fn_chk[s]
      if ar >= 0
        if ar != argc && problem_start(nm)
          err_sym(s)
          RL.err_s(" takes ")
          RL.err_int(ar)
          RL.err_s(" arguments but is called with ")
          RL.err_int(argc)
          problem_end(nm)
        end
      else
        if problem_start(nm)
          RL.err_s("undefined function ")
          err_sym(s)
          problem_end(nm)
        end
      end
      j = 2
      while j < n
        c = kid(i, j)
        check_expr(c, in_def) if arg?(c)
        j = j &+ 1
      end
    else
      n = kids(i)
      j = 0
      while j < n
        c = kid(i, j)
        check_expr(c, in_def) if !RL.leaf?(c) || kind(c) == RL::IDENT
        j = j &+ 1
      end
    end
  end

  # Tree depth, without recursion: children always have smaller indices.
  def self.tree_depth : Int32
    nn = RL.nodes
    i = 0
    while i < nn
      d = 1
      k = kids(i)
      j = 0
      while j < k
        c = @@depth[kid(i, j)] &+ 1
        d = c if c > d
        j = j &+ 1
      end
      @@depth[i] = d
      i = i &+ 1
    end
    @@depth[RL.root]
  end

  def self.shallow? : Bool
    return true if tree_depth <= MAX_DEPTH
    # point at the outermost node that is too deep
    i = RL.root
    while kids(i) > 0
      deepest = kid(i, 0)
      j = 1
      while j < kids(i)
        deepest = kid(i, j) if @@depth[kid(i, j)] > @@depth[deepest]
        j = j &+ 1
      end
      break if @@depth[i] <= MAX_DEPTH
      i = deepest
    end
    RL.err_clear
    RL.err_s("Program is nested too deeply (more than ")
    RL.err_int(MAX_DEPTH)
    RL.err_s(" levels)")
    RL.err_at(RL.origin(i))
    false
  end

  # ---- code emission -------------------------------------------------------------------
  def self.emit(v : Int32) : Nil
    if @@pc >= CODE_MAX
      @@overflow = true
      return
    end
    @@code[@@cbase &+ @@pc] = v
    @@pc = @@pc &+ 1
  end

  def self.emit2(a : Int32, b : Int32) : Nil
    emit(a)
    emit(b)
  end

  def self.patch(at : Int32, v : Int32) : Nil
    @@code[@@cbase &+ at] = v if at >= 0 && at < CODE_MAX
  end

  def self.tick(n : Int32) : Nil
    emit2(OP_TICK, n)
  end

  # Slot of sym s in the function being compiled (allocated on first use).
  def self.slot(s : Int32) : Int32
    return -1 if @@mode != MODE_FRAME
    if @@slot_epoch[s] != @@epoch
      @@slot_epoch[s] = @@epoch
      @@slot_of[s] = @@nslots
      @@nslots = @@nslots &+ 1
    end
    @@slot_of[s]
  end

  def self.begin_function : Nil
    @@epoch = @@epoch &+ 1
    @@nslots = 0
  end

  def self.builtin_id(leaf : Int32) : Int32
    return B_PUTS if RL.leaf_is?(leaf, "puts")
    return B_RAND if RL.leaf_is?(leaf, "rand")
    return B_SQRT if RL.leaf_is?(leaf, "sqrt")
    return B_SIN if RL.leaf_is?(leaf, "sin")
    return B_COS if RL.leaf_is?(leaf, "cos")
    return B_TAN if RL.leaf_is?(leaf, "tan")
    return B_ATAN if RL.leaf_is?(leaf, "atan")
    return B_SCAN if RL.leaf_is?(leaf, "scan")
    return B_CANNON if RL.leaf_is?(leaf, "cannon")
    return B_DRIVE if RL.leaf_is?(leaf, "drive")
    return B_DAMAGE if RL.leaf_is?(leaf, "damage")
    return B_SPEED if RL.leaf_is?(leaf, "speed")
    return B_LOC_X if RL.leaf_is?(leaf, "loc_x")
    return B_LOC_Y if RL.leaf_is?(leaf, "loc_y")
    B_SLEEP
  end

  # Decimal value of a number leaf; false (with an error) when it does not
  # fit an Int32 (upstream's String#to_i32 raises there).
  @@num = 0

  def self.number(leaf : Int32) : Bool
    p = RL.src + RL.start(leaf).to_i64!
    n = RL.length(leaf)
    v = 0_i64
    k = 0
    while k < n
      v = v &* 10 &+ (p[k] &- 0x30_u8).to_i64!
      if v > 2147483647_i64
        RL.err_clear
        RL.err_s("Number is too large for 32 bits")
        RL.err_at(RL.start(leaf))
        @@overflow = true
        return false
      end
      k = k &+ 1
    end
    @@num = v.to_i32!
    true
  end

  def self.expr(i : Int32) : Nil
    ru = rule(i)
    if ru == RL::R_LEX
      t = kind(i)
      if t == RL::NUMBER
        return unless number(i)
        emit2(OP_PUSH, @@num)
        tick(1)
      elsif t == RL::STRING
        emit(OP_PUSHS)
        emit2(RL.start(i) &+ 1, RL.length(i) &- 2)
        tick(1)
      elsif t == RL::IDENT
        s = sym(i)
        emit(OP_LOAD)
        emit(s)
        emit2(slot(s), @@mode)
      else # zero-argument builtin
        tick(2)
        emit2(OP_BUILTIN, builtin_id(i))
      end
    elsif ru == RL::R_LITERAL
      emit2(OP_PUSH, kind(kid(i, 0)) == RL::K_TRUE ? 1 : 0)
      tick(1)
    elsif ru == RL::R_PAREN
      expr(kid(i, 1))
    elsif ru == RL::R_NEG
      expr(kid(i, 1))
      emit(OP_NEG)
      tick(1)
    elsif ru >= RL::R_MUL && ru <= RL::R_OR
      expr(kid(i, 0))
      expr(kid(i, 2))
      emit2(OP_BINOP, kind(kid(i, 1)))
      tick(1)
    elsif ru == RL::R_ASSIGN
      expr(kid(i, 2))
      tick(1)
      s = sym(lexeme(kid(i, 0)))
      emit(OP_STORE)
      emit(s)
      emit2(slot(s), @@mode)
    elsif ru == RL::R_OPASSIGN
      expr(kid(i, 2))
      s = sym(lexeme(kid(i, 0)))
      t = kind(kid(i, 1))
      op = t == RL::ADDA ? RL::ADD : (t == RL::SUBA ? RL::SUB : (t == RL::MULA ? RL::MUL : RL::MOD))
      emit2(OP_OPASSIGN, op)
      emit(s)
      emit2(slot(s), @@mode)
      tick(3)
    elsif ru == RL::R_CALL0
      tick(2)
      emit2(OP_BUILTIN, builtin_id(lexeme(i)))
    elsif ru == RL::R_CALL1 || ru == RL::R_COMMAND1 || ru == RL::R_CALL2 || ru == RL::R_COMMAND2
      n = kids(i)
      j = 1
      while j < n
        c = kid(i, j)
        expr(c) if arg?(c)
        j = j &+ 1
      end
      tick(2)
      emit2(OP_BUILTIN, builtin_id(kid(i, 0)))
    elsif ru == RL::R_CALL
      n = kids(i)
      argc = 0
      j = 2
      while j < n
        c = kid(i, j)
        if arg?(c)
          expr(c)
          argc = argc &+ 1
        end
        j = j &+ 1
      end
      tick(3)
      emit(OP_CALL)
      emit2(sym(lexeme(kid(i, 0))), argc)
    end
  end

  # Statements (STMT children) of a block from child `from` up to (not
  # including) the next non-statement child; returns that child's index.
  def self.stmts(block : Int32, from : Int32) : Int32
    n = kids(block)
    j = from
    while j < n && kind(kid(block, j)) == RL::STMT
      stmt(kid(block, j))
      j = j &+ 1
    end
    j
  end

  def self.body(block : Int32) : Nil
    n = kids(block)
    j = 0
    while j < n
      c = kid(block, j)
      stmt(c) if kind(c) == RL::STMT
      j = j &+ 1
    end
  end

  def self.stmt(st : Int32) : Nil
    ru = rule(st)
    if ru == RL::R_EXPRSTMT
      expr(kid(st, 0))
      emit(OP_SETLAST)
      tick(1)
    elsif ru == RL::R_RETURN
      if kids(st) > 2
        expr(kid(st, 1))
      else
        emit2(OP_PUSH, 0)
      end
      tick(1)
      emit(OP_RET)
    elsif ru == RL::R_BREAK
      tick(1)
      emit2(OP_POPN, @@loop_cases) if @@loop_cases > 0
      emit(OP_JMP)
      emit(@@loop_exit) # patch chain
      @@loop_exit = @@pc &- 1
    elsif ru == RL::R_IF
      emit(OP_LAST0)
      ends = -1 # chain of jumps to the end
      n = kids(st)
      j = 0
      while j < n
        c = kid(st, j)
        t = kind(c)
        if t == RL::IF_HEAD || t == RL::ELSIF_HEAD
          expr(kid(c, 1))
          tick(1)
          emit(OP_JF)
          skip = @@pc
          emit(-1)
          j = stmts(st, j &+ 1)
          emit(OP_JMP)
          emit(ends)
          ends = @@pc &- 1
          patch(skip, @@pc)
        elsif t == RL::K_ELSE
          j = stmts(st, j &+ 2)
        else
          j = j &+ 1
        end
      end
      patch_chain(ends, @@pc)
    elsif ru == RL::R_WHILE || ru == RL::R_UNTIL
      outer_exit = @@loop_exit
      outer_cases = @@loop_cases
      @@loop_exit = -1
      @@loop_cases = 0
      top = @@pc
      expr(kid(kid(st, 0), 1))
      tick(1)
      emit2(ru == RL::R_WHILE ? OP_JF : OP_JT, -1)
      exit_at = @@pc &- 1
      body(st)
      emit2(OP_JMP, top)
      patch(exit_at, @@pc)
      patch_chain(@@loop_exit, @@pc)
      emit(OP_LAST0)
      @@loop_exit = outer_exit
      @@loop_cases = outer_cases
    elsif ru == RL::R_CASE
      expr(kid(kid(st, 0), 1)) # the subject stays on the stack
      emit(OP_LAST0)
      @@loop_cases = @@loop_cases &+ 1
      ends = -1
      n = kids(st)
      j = 1
      while j < n
        c = kid(st, j)
        t = kind(c)
        if t == RL::WHEN_HEAD
          expr(kid(c, 1))
          emit(OP_CASEEQ)
          tick(1)
          emit(OP_JF)
          skip = @@pc
          emit(-1)
          j = stmts(st, j &+ 1)
          emit(OP_JMP)
          emit(ends)
          ends = @@pc &- 1
          patch(skip, @@pc)
        elsif t == RL::K_ELSE
          j = stmts(st, j &+ 2)
        else
          j = j &+ 1
        end
      end
      patch_chain(ends, @@pc)
      emit2(OP_POPN, 1)
      @@loop_cases = @@loop_cases &- 1
    elsif ru == RL::R_GLOBAL
      expr(kid(st, 4))
      emit2(OP_SETGLOBAL, sym(kid(st, 2)))
      emit(OP_LAST0)
    elsif ru == RL::R_MAIN
      emit2(OP_FAIL, 1) # upstream: "cannot execute main"
    end
    # R_DEF inside a block: rejected by the checker
  end

  def self.patch_chain(at : Int32, target : Int32) : Nil
    while at >= 0 && at < CODE_MAX
      nxt = @@code[@@cbase &+ at]
      @@code[@@cbase &+ at] = target
      at = nxt
    end
  end

  # ---- whole program -------------------------------------------------------------
  # Parse, check and compile src[0, n] as robot r. False with RL.error set.
  def self.load(r : Int32, p : UInt8*, n : Int32) : Bool
    return false unless setup
    @@r = r
    @@cbase = r &* CODE_MAX
    @@sbase = r &* SYM_MAX
    @@nsym[r] = 0
    @@code_len[r] = 0
    @@name_len[r] = 0
    @@init_entry[r] = 0
    @@main_entry[r] = 0
    @@main_slots[r] = 0
    @@pc = 0
    @@overflow = false
    @@loop_cases = 0
    @@loop_exit = -1
    ok = RL.parse(p, n)
    # keep the source: string literals, names and messages point into it
    d = src(r)
    k = 0
    lim = n < RL::SRC_MAX ? n : RL::SRC_MAX
    while k < lim
      d[k] = p[k]
      k = k &+ 1
    end
    d[lim] = 0_u8
    @@src_len[r] = lim
    return false unless ok
    # symbols
    i = 0
    nn = RL.nodes
    while i < nn
      @@tok_sym[i] = -1
      if RL.leaf?(i) && RL.kind(i) == RL::IDENT
        s = intern(i)
        if s < 0
          RL.err_clear
          RL.err_s("Program has too many names")
          RL.err_at(RL.start(i))
          return false
        end
        @@tok_sym[i] = s
      end
      i = i &+ 1
    end
    s = 0
    while s < SYM_MAX
      @@fn_entry[@@sbase &+ s] = -1
      @@fn_arity[@@sbase &+ s] = 0
      @@fn_slots[@@sbase &+ s] = 0
      s = s &+ 1
    end
    return false unless shallow?
    return false unless check_program
    root = RL.root
    nk = kids(root)
    # functions
    emit(OP_END) # address 0 is never a valid entry
    j = 0
    while j < nk
      st = kid(root, j)
      if rule(st) == RL::R_DEF
        head = kid(st, 0)
        fs = sym(head_ident(head, 0))
        begin_function
        @@mode = MODE_FRAME
        np = head_idents(head)
        q = 1
        while q < np
          slot(sym(head_ident(head, q))) # parameters take slots 0..np-2
          q = q &+ 1
        end
        @@fn_entry[@@sbase &+ fs] = @@pc
        @@fn_arity[@@sbase &+ fs] = np &- 1
        body(st)
        emit(OP_RETLAST)
        @@fn_slots[@@sbase &+ fs] = @@nslots
      end
      j = j &+ 1
    end
    # main
    @@main_entry[r] = @@pc
    begin_function
    @@mode = MODE_FRAME
    j = 0
    while j < nk
      st = kid(root, j)
      if rule(st) == RL::R_MAIN
        body(st)
        set_name(kid(kid(st, 0), 2))
        break
      end
      j = j &+ 1
    end
    emit(OP_END)
    @@main_slots[r] = @@nslots
    # top level, run once
    @@init_entry[r] = @@pc
    j = 0
    while j < nk
      st = kid(root, j)
      ru = rule(st)
      if ru == RL::R_GLOBAL
        @@mode = MODE_NONE
        expr(kid(st, 4))
        emit2(OP_SETGLOBAL, sym(kid(st, 2)))
      elsif ru == RL::R_EXPRSTMT && rule(kid(st, 0)) == RL::R_ASSIGN
        e = kid(st, 0)
        @@mode = MODE_NONE
        expr(kid(e, 2))
        tick(1)
        emit2(OP_SETCONST, sym(lexeme(kid(e, 0))))
        tick(1)
      elsif ru != RL::R_DEF && ru != RL::R_MAIN
        @@mode = MODE_CONST
        emit(OP_CFRAME)
        stmt(st)
        emit(OP_CFRAME_END)
      end
      j = j &+ 1
    end
    emit(OP_ENDINIT)
    if @@overflow
      if RL.error_len == 0
        RL.err_s("Program is too large (more than ")
        RL.err_int(CODE_MAX)
        RL.err_s(" code words)")
      end
      return false
    end
    @@code_len[r] = @@pc
    true
  end

  # Robot name from main("Name"), quotes stripped.
  def self.set_name(leaf : Int32) : Nil
    p = src(@@r) + (RL.start(leaf) &+ 1).to_i64!
    n = RL.length(leaf) &- 2
    n = NAME_MAX if n > NAME_MAX
    d = name(@@r)
    k = 0
    while k < n
      d[k] = p[k]
      k = k &+ 1
    end
    @@name_len[@@r] = n
  end
end
