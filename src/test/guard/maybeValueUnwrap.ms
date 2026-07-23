// nim-guard: value-type Maybe (`T | null`, T a value type) unwraps via `as T`, `?? d`, and postfix `!`
//
// INVARIANT: for a value type T (number/bool), a `T | null` value (Maybe<T>
//   carrier { value, present }) yields the plain payload through all three TS
//   unwraps — `x as T` (nullableLower rule 1c), `x ?? default` (checker
//   inferBinaryOp), and `x!` (parser postfix -> TypeAssertion sentinel "!" ->
//   rule 1c). Each must read `.value`, not leave the carrier struct.
// NIM-REF: §1 "Value-type Maybe unwrap operators" — DIVERGE-INCOMPLETE -> SAME.
//   The only working extraction was flow-narrow on an identifier (rule 1). `as`
//   on a cast-expr, `??` (typed as the carrier), and `!` (absent in parser) all
//   skipped it, leaking Maybe_pN into arithmetic ("operand ... where arithmetic
//   type required").
//
// WHAT IT CATCHES: any of the three unwraps regressing to leave the carrier —
//   RED = build failure (Maybe struct in arithmetic) or wrong value. Proven RED
//   on the pre-fix binary (as/?? leaked, ! did not parse); GREEN post-fix.
//
// No RC balance directive — signal is build-failure / wrong-value-throw.

function pickN(p: boolean, n: number): number | null { if (p) return n; return null; }

function main(): void {
	const a = pickN(true, 7) as number;
	if (!(a < 10)) { throw "GUARD RED: `as number` did not unwrap value-type Maybe"; }

	const b = pickN(false, 0) ?? 42;
	if (b !== 42) { throw "GUARD RED: `?? default` did not select default on absent"; }
	const c = pickN(true, 5) ?? 42;
	if (c !== 5) { throw "GUARD RED: `?? default` wrong on present value"; }

	const d = pickN(true, 9)!;
	if (d + 1 !== 10) { throw "GUARD RED: postfix `!` did not unwrap value-type Maybe"; }

	console.log("maybeValueUnwrap ok");
}
main();
