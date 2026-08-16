// nim-guard: actor spawn static rules — S1/S3/E40 must keep firing
//
// INVARIANT (PARALOCK I4/I5 + E40, Amendment I4/I5 §7.3): inside an actor
//   method a spawn thunk cannot capture `this` (S1/E61) and cannot write a
//   captured field — deep, through member/index chains (S3/E62); a direct
//   `await spawn(...)` in a loop body warns (E40/E41). Swift @Sendable +
//   Pony box precedents. Enforcement: walkActorSpawnRules (checkExprPass,
//   hooked from checkSpawnCaptures) + detectSequentialAwaitSpawn (checkPass
//   loop checkers).
// NIM-REF: PARALOCK §7.3 Amendment I4/I5.
//
// WHAT IT CATCHES: a checker refactor silently dropping the rules — exactly
//   how Phase 6 sat unenforced pre-2026-07-22 (`spawn(() => this.f = 1)`
//   compiled clean for months). The directives below flip run.sh into
//   errorcheck mode: this file must FAIL to build with every listed tag in
//   the log; compiling clean = drift.
//
// RED MEANS: the checkSpawnCaptures hook or the loop-checker walk lost a
//   rule, or the message tags changed (retag only with an amendment).
//   Proven red 2026-07-22 against the pre-rules binary (it builds this file
//   clean → "compiled clean — a checker rule was dropped").
//
// NOTE: needs a HEAD-matched MSC (MSC=./msc2 or a resynced install) — an
//   older msc predates the rules and shows red by design.
//
// GUARD-CHECK-FAIL PARALOCK S1/E61
// GUARD-CHECK-FAIL PARALOCK S3/E62
// GUARD-CHECK-FAIL PARALOCK E40/E41

actor GuardActor {
    n: number = 0;

    s1(): number {
        const r = await spawn(() => { console.log(this); return 0; });
        return r;
    }

    s3(): number {
        const r = await spawn(() => { this.n = 5; return 0; });
        return r;
    }
}

async function main(): Promise<void> {
    const xs: number[] = [1, 2];
    for (const x of xs) {
        const r = await spawn(() => x);
    }
}

await main();
