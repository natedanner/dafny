include "CompilerCommon.dfy"
include "Library.dfy"
include "Values.dfy"

module Interp {
  import Lib.Debug
  import opened Lib.Datatypes
  import opened DafnyCompilerCommon.AST
  import opened DafnyCompilerCommon.Predicates
  import V = Values

  predicate method Pure1(e: Expr) {
    match e {
      case Var(_) => true
      case Literal(lit) => true
      case Abs(vars, body) => true
      case Apply(Lazy(op), args: seq<Expr>) =>
        true
      case Apply(Eager(op), args: seq<Expr>) =>
        match op {
          case UnaryOp(uop: UnaryOp.Op) => true
          case BinaryOp(bop: BinaryOp) => true
          case TernaryOp(top: TernaryOp) => true
          case DataConstructor(name: Path, typeArgs: seq<Type.Type>) => true
          case Builtin(Display(_)) => true
          case Builtin(Print) => false
          case MethodCall(classType, receiver, typeArgs) => false
          case FunctionCall() => true
        }
      case Block(stmts: seq<Expr>) => true
      case If(cond: Expr, thn: Expr, els: Expr) => true
    }
  }

  predicate method Pure(e: Expr) {
    Predicates.Deep.All_Expr(e, Pure1)
  }

  predicate method SupportsInterp1(e: Expr) {
    AST.Exprs.WellFormed(e) &&
    match e {
      case Var(_) => true
      case Literal(lit) => true
      case Abs(vars, body) => true
      case Apply(Lazy(op), args: seq<Expr>) =>
        true
      case Apply(Eager(op), args: seq<Expr>) =>
        match op {
          case UnaryOp(uop) => Debug.TODO(false)
          case BinaryOp(bop) => true
          case TernaryOp(top: TernaryOp) => true
          case DataConstructor(name: Path, typeArgs: seq<Type.Type>) => Debug.TODO(false)
          case Builtin(Display(_)) => true
          case Builtin(Print()) => false
          case MethodCall(classType, receiver, typeArgs) => false
          case FunctionCall() => true
        }
      case Block(stmts: seq<Expr>) => Debug.TODO(false)
      case If(cond: Expr, thn: Expr, els: Expr) => true
    }
  }

  predicate method SupportsInterp(e: Expr) {
    Predicates.Deep.All_Expr(e, SupportsInterp1)
  }

  lemma SupportsInterp_Pure(e: Expr)
    requires SupportsInterp1(e)
    ensures Pure1(e)
  {}

  type Context = map<string, V.T>

  // FIXME many "Invalid" below should really be type errors

  datatype InterpError =
    | TypeError(e: Expr, value: V.T, expected: Type) // TODO rule out type errors through Wf predicate?
    | Invalid(e: Expr) // TODO rule out in Wf predicate?
    | Unsupported(e: Expr) // TODO rule out in SupportsInterp predicate
    | OutOfIntBounds(x: int, low: Option<int>, high: Option<int>)
    | OutOfSeqBounds(collection: V.T, idx: V.T)
    | UnboundVariable(v: string)
    | SignatureMismatch(vars: seq<string>, argvs: seq<V.T>)
    | DivisionByZero
  {
    function method ToString() : string {
      match this // TODO include values in messages
        case TypeError(e, value, expected) => "Type mismatch"
        case Invalid(e) => "Invalid expression"
        case Unsupported(e) => "Unsupported expression"
        case OutOfIntBounds(x, low, high) => "Out-of-bounds value"
        case OutOfSeqBounds(v, i) => "Out-of-bounds index"
        case UnboundVariable(v) => "Unbound variable '" + v + "'"
        case SignatureMismatch(vars, argvs) => "Wrong number of arguments in function call"
        case DivisionByZero() => "Division by zero"
    }
  }

  datatype InterpSuccess<A> =
    | OK(v: A, ctx: Context)

  type InterpResult<A> =
    Result<InterpSuccess<A>, InterpError>

  type PureInterpResult<A> =
    Result<A, InterpError>

  function method LiftPureResult<A>(ctx: Context, r: PureInterpResult<A>)
    : InterpResult<A>
  {
    var v :- r;
    Success(OK(v, ctx))
  }

  function method InterpExpr(e: Expr, ctx: Context := map[]) : InterpResult<V.T>
    requires SupportsInterp(e)
    decreases e, 1
  {
    Predicates.Deep.AllImpliesChildren(e, SupportsInterp1);
    match e {
      case Var(v) =>
        var val :- TryGet(ctx, v, UnboundVariable(v));
        Success(OK(val, ctx))
      case Abs(vars, body) =>
        Success(OK(V.Abs(vars, body), ctx))
      case Literal(lit) =>
        Success(OK(InterpLiteral(lit), ctx))
      case Apply(Lazy(op), args: seq<Expr>) =>
        InterpLazy(e, ctx)
      case Apply(Eager(op), args: seq<Expr>) =>
        var OK(argvs, ctx) :- InterpExprs(args, ctx);
        LiftPureResult(ctx, match op {
            case BinaryOp(bop: BinaryOp) =>
              InterpBinaryOp(e, bop, argvs[0], argvs[1])
            case TernaryOp(top: TernaryOp) =>
              InterpTernaryOp(e, top, argvs[0], argvs[1], argvs[2])
            case Builtin(Display(ty)) =>
              InterpDisplay(e, ty.kind, argvs)
            case FunctionCall() =>
              :- Need(args[0].Abs?, Invalid(e));
              InterpFunctionCall(e, args[0], argvs[1..])
          })
      case If(cond, thn, els) =>
        var OK(condv, ctx) :- InterpExprWithType(cond, Type.Bool, ctx);
        if condv.b then InterpExpr(thn, ctx) else InterpExpr(els, ctx)
    }
  }

  function method {:opaque} TryGet<K, V>(m: map<K, V>, k: K, err: InterpError)
    : (r: PureInterpResult<V>)
    ensures r.Success? ==> k in m && r.value == m[k]
    ensures r.Failure? ==> k !in m && r.error == err
  {
    if k in m then Success(m[k]) else Failure(err)
  }

  function method TryGetPair<K, V>(m: map<K, V>, k: K, err: InterpError)
    : (r: PureInterpResult<(K, V)>)
    ensures r.Success? ==> k in m && r.value == (k, m[k])
    ensures r.Failure? ==> k !in m && r.error == err
  {
    if k in m then Success((k, m[k])) else Failure(err)
  }

  function method MapOfPairs<K, V>(pairs: seq<(K, V)>, acc: map<K, V> := map[])
    : (m: map<K, V>)
  {
    if pairs == [] then acc
    else MapOfPairs(pairs[1..], acc[pairs[0].0 := pairs[0].1])
  }

  function method InterpExprWithType(e: Expr, ty: Type, ctx: Context)
    : (r: InterpResult<V.T>)
    requires SupportsInterp(e)
    decreases e, 2
    ensures r.Success? ==> r.value.v.HasType(ty)
  {
    var OK(val, ctx) :- InterpExpr(e, ctx);
    :- Need(val.HasType(ty), TypeError(e, val, ty));
    Success(OK(val, ctx))
  }

  function method NeedTypes(es: seq<Expr>, vs: seq<V.T>, ty: Type)
    : (r: Outcome<InterpError>)
    requires |es| == |vs|
    decreases |es|
    // DISCUSS: Replacing this with <==> doesn't verify
    ensures r.Pass? ==> forall v | v in vs :: v.HasType(ty)
    ensures r.Pass? <== forall v | v in vs :: v.HasType(ty)
  {
    if es == [] then
      assert vs == []; Pass
    else
      // DISCUSS: No `:-` for outcomes?
      // DISCUSS: should match accept multiple discriminands? (with lazy evaluation?)
      match Need(vs[0].HasType(ty), TypeError(es[0], vs[0], ty))
        case Pass =>
          assert vs[0].HasType(ty);
          match NeedTypes(es[1..], vs[1..], ty) { // TODO check that compiler does this efficiently
            case Pass => assert forall v | v in vs[1..] :: v.HasType(ty); Pass
            case fail => fail
          }
        case fail => fail
  }

  function method InterpExprs(es: seq<Expr>, ctx: Context)
    : (r: InterpResult<seq<V.T>>)
    requires forall e | e in es :: SupportsInterp(e)
    ensures r.Success? ==> |r.value.v| == |es|
  { // TODO generalize into a FoldResult function
    if es == [] then Success(OK([], ctx))
    else
      var OK(v, ctx) :- InterpExpr(es[0], ctx);
      var OK(vs, ctx) :- InterpExprs(es[1..], ctx);
      Success(OK([v] + vs, ctx))
  }

  function method InterpLiteral(a: AST.Exprs.Literal) : V.T {
    match a
      case LitBool(b: bool) => V.Bool(b)
      case LitInt(i: int) => V.Int(i)
      case LitReal(r: real) => V.Real(r)
      case LitChar(c: char) => V.Char(c)
      case LitString(s: string, verbatim: bool) =>
        V.Seq(seq(|s|, i requires 0 <= i < |s| => V.Char(s[i])))
  }

  function method InterpLazy(e: Expr, ctx: Context)
    : InterpResult<V.T>
    requires e.Apply? && e.aop.Lazy? && SupportsInterp(e)
    decreases e, 0
  {
    // DISCUSS: An alternative implementation would be to evaluate but discard
    // the second context if a short-circuit happens.
    Predicates.Deep.AllImpliesChildren(e, SupportsInterp1);
    var op, e0, e1 := e.aop.lOp, e.args[0], e.args[1];
    var OK(v0, ctx0) :- InterpExprWithType(e0, Type.Bool, ctx);
    match (op, v0)
      case (And, Bool(false)) => Success(OK(V.Bool(false), ctx0))
      case (Or,  Bool(true))  => Success(OK(V.Bool(true), ctx0))
      case (Imp, Bool(false)) => Success(OK(V.Bool(true), ctx0))
      case (_,   Bool(b)) =>
        assert op in {Exprs.And, Exprs.Or, Exprs.Imp};
        InterpExprWithType(e1, Type.Bool, ctx0)
  }

  // Alternate implementation of ``InterpLazy``: less efficient but more closely
  // matching intuition.
  function method InterpLazy_Eagerly(e: Expr, ctx: Context)
    : InterpResult<V.T>
    requires e.Apply? && e.aop.Lazy? && SupportsInterp(e)
    decreases e, 0
  {
    Predicates.Deep.AllImpliesChildren(e, SupportsInterp1);
    var op, e0, e1 := e.aop.lOp, e.args[0], e.args[1];
    var OK(v0, ctx0) :- InterpExprWithType(e0, Type.Bool, ctx);
    var OK(v1, ctx1) :- InterpExprWithType(e1, Type.Bool, ctx0);
    match (op, v0, v1)
      case (And, Bool(b0), Bool(b1)) =>
        Success(OK(V.Bool(b0 && b1), if b0 then ctx1 else ctx0))
      case (Or,  Bool(b0), Bool(b1)) =>
        Success(OK(V.Bool(b0 || b1), if b0 then ctx0 else ctx1))
      case (Imp, Bool(b0), Bool(b1)) =>
        Success(OK(V.Bool(b0 ==> b1), if b0 then ctx1 else ctx0))
  }

  lemma InterpLazy_Complete(e: Expr, ctx: Context)
    requires e.Apply? && e.aop.Lazy? && SupportsInterp(e)
    requires InterpLazy(e, ctx).Failure?
    ensures InterpLazy_Eagerly(e, ctx) == InterpLazy(e, ctx)
  {}

  lemma InterpLazy_Eagerly_Sound(e: Expr, ctx: Context)
    requires e.Apply? && e.aop.Lazy? && SupportsInterp(e)
    requires InterpLazy_Eagerly(e, ctx).Success?
    ensures InterpLazy_Eagerly(e, ctx) == InterpLazy(e, ctx)
  {}

  function method InterpBinaryOp(expr: Expr, bop: AST.BinaryOp, v0: V.T, v1: V.T)
    : PureInterpResult<V.T>
  {
    match bop
      case Numeric(op) => InterpBinaryNumeric(expr, op, v0, v1)
      case Logical(op) => InterpBinaryLogical(expr, op, v0, v1)
      case Eq(op) => match op { // FIXME which types is this Eq applicable to (vs. the type-specific ones?)
        case EqCommon() => Success(V.Bool(v0 == v1))
        case NeqCommon() => Success(V.Bool(v0 != v1))
      }
      case BV(op) => Failure(Unsupported(expr))
      case Char(op) => InterpBinaryChar(expr, op, v0, v1)
      case Sets(op) => InterpBinarySets(expr, op, v0, v1)
      case Multisets(op) => InterpBinaryMultisets(expr, op, v0, v1)
      case Sequences(op) => InterpBinarySequences(expr, op, v0, v1)
      case Maps(op) => InterpBinaryMaps(expr, op, v0, v1)
      case Datatypes(op) => Failure(Unsupported(expr))
  }

  function method InterpBinaryNumeric(expr: Expr, op: BinaryOps.Numeric, v0: V.T, v1: V.T)
    : PureInterpResult<V.T>
  {
    match (v0, v1) {
      // Separate functions to more easily check exhaustiveness
      case (Int(x1), Int(x2)) => InterpBinaryInt(expr, op, x1, x2)
      case (Char(x1), Char(x2)) => InterpBinaryNumericChar(expr, op, x1, x2)
      case (Real(x1), Real(x2)) => InterpBinaryReal(expr, op, x1, x2)
      case _ => Failure(Invalid(expr)) // FIXME: Wf
    }
  }

  function method CheckDivisionByZero(b: bool) : Outcome<InterpError> {
    if b then Fail(DivisionByZero) else Pass
  }

  function method InterpBinaryInt(expr: Expr, bop: AST.BinaryOps.Numeric, x1: int, x2: int)
    : PureInterpResult<V.T>
  {
    match bop {
      case Lt() => Success(V.Bool(x1 < x2))
      case Le() => Success(V.Bool(x1 <= x2))
      case Ge() => Success(V.Bool(x1 >= x2))
      case Gt() => Success(V.Bool(x1 > x2))
      case Add() => Success(V.Int(x1 + x2))
      case Sub() => Success(V.Int(x1 - x2))
      case Mul() => Success(V.Int(x1 * x2))
      case Div() => :- CheckDivisionByZero(x2 == 0); Success(V.Int(x1 / x2))
      case Mod() => :- CheckDivisionByZero(x2 == 0); Success(V.Int(x1 % x2))
    }
  }

  function method NeedIntBounds(x: int, low: int, high: int) : PureInterpResult<int> {
    :- Need(low <= x < high, OutOfIntBounds(x, Some(low), Some(high)));
    Success(x)
  }

  function method InterpBinaryNumericChar(expr: Expr, bop: AST.BinaryOps.Numeric, x1: char, x2: char)
    : PureInterpResult<V.T>
  {
    match bop { // FIXME: These first four cases are not used (see InterpBinaryChar instead)
      case Lt() => Success(V.Bool(x1 < x2))
      case Le() => Success(V.Bool(x1 <= x2))
      case Ge() => Success(V.Bool(x1 >= x2))
      case Gt() => Success(V.Bool(x1 > x2))
      case Add() => var x :- NeedIntBounds(x1 as int + x2 as int, 0, 256); Success(V.Char(x as char))
      case Sub() => var x :- NeedIntBounds(x1 as int - x2 as int, 0, 256); Success(V.Char(x as char))
      case Mul() => Failure(Unsupported(expr))
      case Div() => Failure(Unsupported(expr))
      case Mod() => Failure(Unsupported(expr))
    }
  }

  function method InterpBinaryReal(expr: Expr, bop: AST.BinaryOps.Numeric, x1: real, x2: real)
    : PureInterpResult<V.T>
  {
    match bop {
      case Lt() => Success(V.Bool(x1 < x2))
      case Le() => Success(V.Bool(x1 <= x2))
      case Ge() => Success(V.Bool(x1 >= x2))
      case Gt() => Success(V.Bool(x1 > x2))
      case Add() => Success(V.Real(x1 + x2))
      case Sub() => Success(V.Real(x1 - x2))
      case Mul() => Success(V.Real(x1 * x2))
      case Div() => :- CheckDivisionByZero(x2 == 0 as real); Success(V.Real(x1 / x2))
      case Mod() => Failure(Unsupported(expr))
    }
  }

  function method InterpBinaryLogical(expr: Expr, op: BinaryOps.Logical, v0: V.T, v1: V.T)
    : PureInterpResult<V.T>
  {
    :- Need(v0.Bool? && v1.Bool?, Invalid(expr));
    match op
      case Iff() =>
        Success(V.Bool(v0.b <==> v1.b))
  }

  function method InterpBinaryChar(expr: Expr, op: AST.BinaryOps.Char, v0: V.T, v1: V.T)
    : PureInterpResult<V.T>
  { // FIXME eliminate distinction between GtChar and GT?
    :- Need(v0.Char? && v1.Char?, Invalid(expr));
    match op
      case LtChar() =>
        Success(V.Bool(v0.c < v1.c))
      case LeChar() =>
        Success(V.Bool(v0.c <= v1.c))
      case GeChar() =>
        Success(V.Bool(v0.c >= v1.c))
      case GtChar() =>
        Success(V.Bool(v0.c > v1.c))
  }

  function method InterpBinarySets(expr: Expr, op: BinaryOps.Sets, v0: V.T, v1: V.T)
    : PureInterpResult<V.T>
  {
    match op
      case SetEq() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Bool(v0.st == v1.st))
      case SetNeq() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Bool(v0.st != v1.st))
      case Subset() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Bool(v0.st <= v1.st))
      case Superset() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Bool(v0.st >= v1.st))
      case ProperSubset() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Bool(v0.st < v1.st))
      case ProperSuperset() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Bool(v0.st > v1.st))
      case Disjoint() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Bool(v0.st !! v1.st))
      case Union() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Set(v0.st + v1.st))
      case Intersection() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Set(v0.st * v1.st))
      case SetDifference() => :- Need(v0.Set? && v1.Set?, Invalid(expr));
        Success(V.Set(v0.st - v1.st))
      case InSet() => :- Need(v1.Set?, Invalid(expr));
        Success(V.Bool(v0 in v1.st))
      case NotInSet() => :- Need(v1.Set?, Invalid(expr));
        Success(V.Bool(v0 !in v1.st))
  }

  function method InterpBinaryMultisets(expr: Expr, op: BinaryOps.Multisets, v0: V.T, v1: V.T)
    : PureInterpResult<V.T>
  {
    match op // DISCUSS
      case MultisetEq() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Bool(v0.ms == v1.ms))
      case MultisetNeq() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Bool(v0.ms != v1.ms))
      case MultiSubset() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Bool(v0.ms <= v1.ms))
      case MultiSuperset() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Bool(v0.ms >= v1.ms))
      case ProperMultiSubset() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Bool(v0.ms < v1.ms))
      case ProperMultiSuperset() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Bool(v0.ms > v1.ms))
      case MultisetDisjoint() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Bool(v0.ms !! v1.ms))
      case MultisetUnion() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Multiset(v0.ms + v1.ms))
      case MultisetIntersection() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Multiset(v0.ms * v1.ms))
      case MultisetDifference() => :- Need(v0.Multiset? && v1.Multiset?, Invalid(expr));
        Success(V.Multiset(v0.ms - v1.ms))
      case InMultiset() => :- Need(v1.Multiset?, Invalid(expr));
        Success(V.Bool(v0 in v1.ms))
      case NotInMultiset() => :- Need(v1.Multiset?, Invalid(expr));
        Success(V.Bool(v0 !in v1.ms))
      case MultisetSelect() => :- Need(v0.Multiset?, Invalid(expr));
        Success(V.Int(v0.ms[v1]))
  }

  function method InterpBinarySequences(expr: Expr, op: BinaryOps.Sequences, v0: V.T, v1: V.T)
    : PureInterpResult<V.T>
  {
    match op
      case SeqEq() => :- Need(v0.Seq? && v1.Seq?, Invalid(expr));
        Success(V.Bool(v0.sq == v1.sq))
      case SeqNeq() => :- Need(v0.Seq? && v1.Seq?, Invalid(expr));
        Success(V.Bool(v0.sq != v1.sq))
      case Prefix() => :- Need(v0.Seq? && v1.Seq?, Invalid(expr));
        Success(V.Bool(v0.sq <= v1.sq))
      case ProperPrefix() => :- Need(v0.Seq? && v1.Seq?, Invalid(expr));
        Success(V.Bool(v0.sq < v1.sq))
      case Concat() => :- Need(v0.Seq? && v1.Seq?, Invalid(expr));
        Success(V.Seq(v0.sq + v1.sq))
      case InSeq() => :- Need(v1.Seq?, Invalid(expr));
        Success(V.Bool(v0 in v1.sq))
      case NotInSeq() => :- Need(v1.Seq?, Invalid(expr));
        Success(V.Bool(v0 !in v1.sq))
      case SeqDrop() => :- NeedValidEndpoint(expr, v0, v1);
        Success(V.Seq(v0.sq[v1.i..]))
      case SeqTake() => :- NeedValidEndpoint(expr, v0, v1);
        Success(V.Seq(v0.sq[..v1.i]))
      case SeqSelect() => :- NeedValidIndex(expr, v0, v1);
        Success(v0.sq[v1.i])
  }

  function method InterpBinaryMaps(expr: Expr, op: BinaryOps.Maps, v0: V.T, v1: V.T)
    : PureInterpResult<V.T>
  {
    match op
      case MapEq() => :- Need(v0.Map? && v1.Map?, Invalid(expr));
        Success(V.Bool(v0.m == v1.m))
      case MapNeq() => :- Need(v0.Map? && v1.Map?, Invalid(expr));
        Success(V.Bool(v0.m != v1.m))
      case MapMerge() => :- Need(v0.Map? && v1.Map?, Invalid(expr));
        Success(V.Map(v0.m + v1.m))
      case MapSubtraction() => :- Need(v0.Map? && v1.Set?, Invalid(expr));
        Success(V.Map(v0.m - v1.st))
      case InMap() => :- Need(v1.Map?, Invalid(expr));
        Success(V.Bool(v0 in v1.m))
      case NotInMap() => :- Need(v1.Map?, Invalid(expr));
        Success(V.Bool(v0 !in v1.m))
      case MapSelect() =>
        :- Need(v0.Map?, Invalid(expr));
        :- Need(v1 in v0.m, Invalid(expr));
        Success(v0.m[v1])
  }

  function method InterpTernaryOp(expr: Expr, top: AST.TernaryOp, v0: V.T, v1: V.T, v2: V.T)
    : PureInterpResult<V.T>
  {
    match top
      case Sequences(op) =>
        InterpTernarySequences(expr, op, v0, v1, v2)
      case Multisets(op) =>
        InterpTernaryMultisets(expr, op, v0, v1, v2)
      case Maps(op) =>
        InterpTernaryMaps(expr, op, v0, v1, v2)
  }

  function method NeedValidIndex(expr: Expr, vs: V.T, vidx: V.T)
    : Outcome<InterpError>
  { // FIXME no monadic operator for combining outcomes?
    match Need(vidx.Int? && vs.Seq?, Invalid(expr))
      case Pass() => Need(0 <= vidx.i < |vs.sq|, OutOfSeqBounds(vs, vidx))
      case fail => fail
  }

  function method NeedValidEndpoint(expr: Expr, vs: V.T, vidx: V.T)
    : Outcome<InterpError>
  {
    match Need(vidx.Int? && vs.Seq?, Invalid(expr))
      case Pass() => Need(0 <= vidx.i <= |vs.sq|, OutOfSeqBounds(vs, vidx))
      case fail => fail
  }

  function method InterpTernarySequences(expr: Expr, op: AST.TernaryOps.Sequences, v0: V.T, v1: V.T, v2: V.T)
    : PureInterpResult<V.T>
  {
    match op
      case SeqUpdate() => :- NeedValidIndex(expr, v0, v1);
        Success(V.Seq(v0.sq[v1.i := v2]))
      case SeqSubseq() =>
        :- NeedValidEndpoint(expr, v0, v2);
        :- Need(v1.Int?, Invalid(expr));
        :- Need(0 <= v1.i <= v2.i, OutOfIntBounds(v1.i, Some(0), Some(v2.i)));
        Success(V.Seq(v0.sq[v1.i..v2.i]))
  }

  function method InterpTernaryMultisets(expr: Expr, op: AST.TernaryOps.Multisets, v0: V.T, v1: V.T, v2: V.T)
    : PureInterpResult<V.T>
  {
    match op
      case MultisetUpdate() =>
        :- Need(v0.Multiset?, Invalid(expr));
        :- Need(v2.Int? && v2.i >= 0, Invalid(expr));
        Success(V.Multiset(v0.ms[v1 := v2.i]))
  }

  function method InterpTernaryMaps(expr: Expr, op: AST.TernaryOps.Maps, v0: V.T, v1: V.T, v2: V.T)
    : PureInterpResult<V.T>
  {
    match op
      case MapUpdate() => :- Need(v0.Map?, Invalid(expr));
        Success(V.Map(v0.m[v1 := v2]))
  }

  function method InterpDisplay(e: Expr, kind: Types.CollectionKind, argvs: seq<V.T>)
    : PureInterpResult<V.T>
  {
    match kind
      case Map(_) => var m :- InterpMapDisplay(e, argvs); Success(V.Map(m))
      case Multiset() => Success(V.Multiset(multiset(argvs)))
      case Seq() => Success(V.Seq(argvs))
      case Set() => Success(V.Set(set s | s in argvs))
  }

  function method InterpMapDisplay(e: Expr, argvs: seq<V.T>)
    : PureInterpResult<map<V.T, V.T>>
  {
    var pairs :- Seq.MapResult(argv => PairOfMapDisplaySeq(e, argv), argvs);
    var acc: map<V.T, V.T> := map[]; // FIXME removing this map triggers a compilation bug in C#
    Success(MapOfPairs(pairs, acc))
  }

  function method PairOfMapDisplaySeq(e: Expr, argv: V.T)
    : PureInterpResult<(V.T, V.T)>
  {
    :- Need(argv.Seq? && |argv.sq| == 2, Invalid(e));
    Success((argv.sq[0], argv.sq[1]))
  }

  function method BuildCallContext(vars: seq<string>, vals: seq<V.T>)
    : Context
    requires |vars| == |vals|
  {
    var acc: Context := map[]; // FIXME removing this map triggers a compilation bug in C#
    MapOfPairs(Seq.Zip(vars, vals), acc)
  }

  function method InterpFunctionCall(e: Expr, fn: Expr, argvs: seq<V.T>)
    : PureInterpResult<V.T>
    requires fn.Abs?
    requires SupportsInterp(fn)
    decreases fn
  {
    Predicates.Deep.AllImpliesChildren(fn, SupportsInterp1);
    :- Need(|fn.vars| == |argvs|, SignatureMismatch(fn.vars, argvs));
    var OK(val, ctx) :- InterpExpr(fn.body, BuildCallContext(fn.vars, argvs));
    Success(val)
  }
}
