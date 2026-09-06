// nim-guard: destructuring rest element (...rest) binds and types correctly
//
// INVARIANT: this is TS-SURFACE — Nim has NO rest destructuring, so there is no
//   reference mechanism to trace to; the contract is ours: `const [a, ...rest] = src`
//   binds rest = src.slice(i, src.length) of the same array type. Before the fix
//   the feature NEVER worked: the parser wraps rest as SpreadExpr{spreadArg}, but
//   BOTH the checker's defineForOfPatternBindings and destructuringLower's rest
//   arm matched NodeKind.Identifier only — rest was skipped everywhere and the
//   use site failed "Undefined variable 'rest'" (fail-loud, not silent). The old
//   transform arm also called slice(i) with ONE arg against a (start, end)
//   signature — doubly dead. A concrete NON-array source (tuple) is a loud
//   checker error ("rest element requires an array source"), not an Inferred
//   binding — verified by probe, not asserted here (run.sh grades exit codes).
//
// WHAT IT CATCHES: either layer regressing to Identifier-only matching, the
//   slice call losing its second (end) argument, or the rest binding losing its
//   Array type (closure capture would type the lifted env field as double/void*).
//
// RED MEANS: SpreadExpr handling dropped out of the checker define loop or the
//   transform rest arm. Proven RED on the pre-fix binary (v0.2.53 through tip
//   d733562a: "Undefined variable 'rest'"); GREEN post-fix.
//
// No RC balance directive — the signal is wrong-value-throw / build failure.

const src: int32[] = [3, 4, 5, 6];

function main(): void {
	// (1) basic: values + length
	const [a, b, ...rest] = src;
	if (a + b != 7) { throw "GUARD RED: leading elems wrong"; }
	if (rest.length != 2) { throw "GUARD RED: rest length wrong"; }
	if (rest[0] != 5 || rest[1] != 6) { throw "GUARD RED: rest contents wrong"; }

	// (2) rest alone
	const [...all] = src;
	if (all.length != 4) { throw "GUARD RED: whole-rest length wrong"; }

	// (3) rest in a closure — env field must carry the Array type
	const fn = (): int32 => { const [x, ...r] = src; return x + r.length; };
	if (fn() != 6) { throw "GUARD RED: closure rest capture wrong"; }

	// (4) for-of destructured rest
	const rows: int32[][] = [[10, 20, 30]];
	for (const [h, ...tail] of rows) {
		if (h != 10) { throw "GUARD RED: for-of head wrong"; }
		if (tail.length != 2 || tail[1] != 30) { throw "GUARD RED: for-of rest wrong"; }
	}

	// (5) string-element array
	const words: string[] = ["a", "b", "c"];
	const [w, ...ws] = words;
	if (w + ws.length.toString() != "a2") { throw "GUARD RED: string rest wrong"; }

	// (6) rest.toString() must not fold to "<object>" (typing regression sentinel)
	const [, , ...r2] = src;
	if (r2.length.toString() != "2") { throw "GUARD RED: rest toString folded to <object>"; }

	console.log("destructureRestElement ok");
}

main();
