// GUARD-JS
// Multi-arg explicit generic instantiation `f<A, B>(...)`.
//
// Pins the contract fixed 2026-09-04 (positional binding in
// inferGenericReturnWithExplicit, parity with the reference's
// explicitGenericInstantiation → setGenericParams + matchGenericParams):
//   1. `Result.ok<int32, string>(5)` binds T and E positionally and compiles
//      without a destination annotation (was: "cannot instantiate: 'E'"
//      while the message advised exactly this syntax).
//   2. `Result.err<int32, string>(...)` binds T even though T appears in no
//      parameter — only the explicit args can supply it.
//   3. Positional ORDER is honored: `Result.ok<string, int32>("x")` yields a
//      string value, `Result.ok<int32, string>(5)` a numeric one.
//   4. A free generic function that NEEDS both explicit args (E unreachable
//      from parameters) instantiates.
//   5. The annotated-destination form and the single-arg explicit form keep
//      working (legacy paths untouched).
// A red guard means the multi-arg explicit binding in callResolve drifted.

function tagged<T, E>(t: T): Result<T, E> {
    return Result.ok<T, E>(t);
}

function expect(actual: string, want: string, name: string): int32 {
    if (actual !== want) {
        console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
        return 1;
    }
    return 0;
}

function main(): int32 {
    const a = Result.ok<int32, string>(5);
    if (!a.ok) { console.log("GUARD-FAIL okBranch: not ok"); return 1; }
    let rc = expect(`${a.value + 1}`, "6", "okMultiArg");

    const b = Result.err<int32, string>("boom");
    if (b.ok) { console.log("GUARD-FAIL errBranch: ok"); return 1; }
    rc += expect(b.error, "boom", "errMultiArg");

    const c = Result.ok<string, int32>("x");
    if (!c.ok) { console.log("GUARD-FAIL okStringBranch: not ok"); return 1; }
    rc += expect(c.value + "!", "x!", "positionalOrder");

    const d = tagged<boolean, string>(true);
    if (!d.ok) { console.log("GUARD-FAIL taggedBranch: not ok"); return 1; }
    rc += expect(`${d.value}`, "true", "freeFnBothArgs");

    const e: Result<int32, string> = Result.ok(7);
    rc += expect(`${e.value}`, "7", "annotatedDestination");

    const f: Vec<int32> = [1, 2, 3];
    rc += expect(`${f.length}`, "3", "noExplicitBaseline");

    if (rc === 0) { console.log("GUARD-OK explicitGenericArgs"); }
    return rc;
}

const rc = main();
if (rc !== 0) { process.exit(rc); }
