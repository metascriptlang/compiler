// nim-guard: unbound generic param at a call site is a CHECK error, not a
// clang error — and not a silent js success.
//
// INVARIANT (checkExprPass inferGenericReturn/-WithExplicit): after arg-driven
//   inference (pass 1) and contextual binding from the expected type (pass 2),
//   every generic param in the inferred return type is bound. A param still
//   unbound has nothing left to bind it — the reference model errors at the
//   call site and substitutes an error type so nothing downstream proceeds
//   with a half-instantiated type. Suppressed only inside a generic class
//   body pre-monomorphization (ctx.inGenericContext), where open params are
//   legitimate and instantiation re-checks with concrete types.
//
// WHAT IT CATCHES: dropping the unbound-param check (or its errorType
//   substitution). Pre-fix behavior: native leaked `Result__S_k25_...` into C
//   and died in CLANG with no source diagnostic; js compiled clean and RAN —
//   a backend parity split. The js lane is the important half.
//
// RED MEANS: a half-instantiated generic type survived the checker again;
//   trace inferGenericReturn's binding passes before touching the gate.
//
// GUARD-CHECK-FAIL cannot instantiate: 'E'
// GUARD-CHECK-FAIL cannot instantiate: 'T'
// GUARD-JS

struct GuardUbS { a: int32; b: string; }

function main(): void {
    const t: GuardUbS = { a: 1, b: "x" };
    const r = Result.ok(t);
    const s: Result<GuardUbS, string> = r;
    if (s.ok) { console.log(s.value.b); }
    const e = Result.err("boom");
    const s2: Result<GuardUbS, string> = e;
    if (!s2.ok) { console.log(s2.error); }
}
main();
