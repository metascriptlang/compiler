// nim-guard: value-type parameters are read-only views
//
// INVARIANT (Nim sem: "cannot assign to" a non-var param; NIM-REF —
//   ccgIntroducedPtr passes value aggregates as T* for cost, and the checker
//   ban is the ONLY thing keeping that pointer unobservable): interior
//   mutation (elem/field write) through a param of value-aggregate type
//   (Vec<T>, T[N], struct, tuple, anonymous object type) must be a checker
//   error. Rebinding the param itself stays legal (local effect only).
//
// WHAT IT CATCHES: dropping the paramMutationAnalysis value-param rule (or
//   the orchestrator call that renders its errors — errors that count but
//   never print regressed exactly this way, compile.ms phase-A dedup) lets
//   `a[0] = 9` on a Vec param silently write the CALLER's buffer on C
//   (probes p1/p2 2026-08-23: Vec leak, struct leak, uint8[3] C-copy but
//   JS-leak — a C↔JS parity break in observable semantics).
//
// RED MEANS: value params became mutable again — the silent-aliasing hole
//   ARRAY-MIGRATION.md was written to kill is back. Run /trace-nim against
//   varpartitions/sem assignment rules.
//
// GUARD-CHECK-FAIL cannot mutate value-type parameter 'a'
// GUARD-CHECK-FAIL cannot mutate value-type parameter 's'
// GUARD-CHECK-FAIL cannot mutate value-type parameter 'p'
// GUARD-CHECK-FAIL cannot mutate value-type parameter 'b'

struct GPt { x: number; }

function mVec(a: Vec<uint8>): void { a[0] = 9; }
function mSized(s: uint8[3]): void { s[0] = 9; }
function mStruct(p: GPt): void { p.x = 9; }
function mAnon(b: { v: number }): void { b.v = 9; }

const v: Vec<uint8> = [1, 2, 3];
mVec(v);
const sa: uint8[3] = [1, 2, 3];
mSized(sa);
const gp: GPt = { x: 1 };
mStruct(gp);
const ab: { v: number } = { v: 1 };
mAnon(ab);
