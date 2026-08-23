// nim-guard: the anonymous-literal adoption BOUNDARY — what must stay rejected
//
// INVARIANT (compat.ms isAnonStructAdoption): an object literal bound without
//   an annotation freezes as `__anonN__...`. It adopts a NAMED VALUE STRUCT
//   only on an EXACT field match (see anonStructAdoption.ms for that half).
//   Two neighbours must stay rejected on BOTH targets:
//     (a) interface target — a reference type; adopting would copy on C while
//         js keeps the alias, so `===` and mutation-visibility would split.
//     (b) extra fields (width subtyping) — the C member-wise copy drops the
//         extra field that the js identity keeps: a built-in parity split.
//   Nim never faces this class: object construction is nominal (S(a: ..)), and
//   its structural world (tuple) has no bridge to the nominal one.
//
// WHAT IT CATCHES: widening the adoption clause (dropping the exact-match or
//   the interface test). The js lane is the important half — without a checker
//   rule js compiles CLEAN and runs silently wrong.
//
// RED MEANS: isAnonStructAdoption admits a pair outside the boundary, or the
//   diagnostic lost the annotate-at-the-literal hint (retag deliberately).
//
// GUARD-CHECK-FAIL Argument type mismatch
// GUARD-CHECK-FAIL annotate at the literal
// GUARD-JS

interface GuardAnonIface { a: int32; b: string; }
struct GuardAnonExact { a: int32; b: string; }

function takeIface(s: GuardAnonIface): void { console.log(s.b); }
function takeExact(s: GuardAnonExact): void { console.log(s.b); }

function main(): void {
    const t = { a: 1, b: "x" };
    takeIface(t);
    const wide = { a: 1, b: "x", c: 9 };
    takeExact(wide);
}
main();
