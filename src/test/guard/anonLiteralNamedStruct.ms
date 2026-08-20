// nim-guard: a frozen anonymous-literal type must not adopt a NAMED struct
//
// INVARIANT (compat.ms isObjectAssignable): an object literal bound without an
//   annotation freezes as `__anonN__...` (anonStructName); no boundary lowering
//   exists for it, so admitting it into a slot of a NAMED value struct compiles
//   on js (types erased, runs silently) and dies at clang on C with two
//   incompatible struct types. The checker must reject at ALL THREE positions
//   — call arg, var init, return — with the annotate-at-the-literal hint.
//   Nim constructs objects nominally (S(a:..)), so this class cannot exist
//   there; the interface (Ref) target was already rejected loudly.
//
// WHAT IT CATCHES: a compat.ms refactor dropping the anon-source clause —
//   the js lane below is the important half: without the clause the js build
//   compiles CLEAN and runs wrong silently (measured 2026-08-18, v0.2.49).
//
// RED MEANS: isObjectAssignable re-admits `__anon* -> named struct`, or the
//   diagnostic lost its position coverage / hint text (retag deliberately).
//
// NOT COVERED (pre-existing, out of scope): anon literal -> EMPTY-NAME inline
//   annotation target (`p: { a: int32, b: string }`) — js runs it correctly
//   today; C fails at clang (naming split __anonN vs msAnon_hash).
//
// GUARD-CHECK-FAIL Argument type mismatch
// GUARD-CHECK-FAIL Return type mismatch
// GUARD-CHECK-FAIL is not assignable to type
// GUARD-CHECK-FAIL annotate at the literal
// GUARD-JS

struct GuardAnonS { a: int32; b: string; }

function takeGuardAnon(s: GuardAnonS): void { console.log(s.b); }

function giveGuardAnon(): GuardAnonS {
    const t = { a: 3, b: "y" };
    return t;
}

function main(): void {
    const t = { a: 1, b: "x" };
    takeGuardAnon(t);
    const u: GuardAnonS = t;
    console.log(u.b);
    console.log(giveGuardAnon().b);
}
main();
