// nim-guard: object rest ({ a, ...rest }) binds, types, and survives for-of
//
// INVARIANT: TS-SURFACE — there is no reference mechanism for object rest, so the
//   contract is ours: `const { a, ...rest } = src` binds rest to an ANONYMOUS
//   STRUCT of the fields the pattern did not name, built by the same derivation
//   the checker uses (destrObjectRestNames/destrObjectRestType). One derivation,
//   two readers — the checker types the binding, the transform emits the literal.
//
// Two independent holes this pins, both proven red on tip 6c9011a0:
//   (1) object rest was skipped in BOTH layers (checker matched ObjectPatternProp
//       only, transform `continue`d past SpreadExpr) — using rest was a loud type
//       error, declaring it silently dropped the binding.
//   (2) for-of over an OBJECT pattern was never lowered at all: forOfLower tested
//       ArrayPattern only, so `for (const { a, b } of ps)` fell into the simple
//       binding branch and every field came out "use of undeclared identifier".
//       That one had nothing to do with rest — plain object for-of was broken.
//
// RED MEANS: the SpreadExpr arm dropped out of checkPass/destructuringLower, or
//   forOfLower went back to ArrayPattern-only, or the rest binding lost its
//   anon-struct type (a string field then reads back as a number/void*).
//
// A source with no remaining fields is a loud checker error ("object rest 'r'
// requires a source with remaining named fields") — verified by probe; run.sh
// grades exit codes so it cannot be asserted from inside a passing build.

interface Row { id: int32; qty: int32; label: string; }

function main(): void {
	const row: Row = { id: 7, qty: 3, label: "widget" };

	// (1) basic: leading field + rest carries BOTH remaining fields with types
	const { id, ...rest } = row;
	if (id != 7) { throw "GUARD RED: leading field wrong"; }
	if (rest.qty != 3) { throw "GUARD RED: rest numeric field wrong"; }
	if (rest.label != "widget") { throw "GUARD RED: rest string field wrong"; }

	// (2) rename + rest — takenKeys must key off propKey, not the alias
	const { id: renamed, ...rest2 } = row;
	if (renamed != 7) { throw "GUARD RED: renamed field wrong"; }
	if (rest2.qty + rest2.label.length != 9) { throw "GUARD RED: rest after rename wrong"; }

	// (3) rest inside a closure — the lifted env field must keep the anon struct
	const fn = (): int32 => { const { id: i2, ...r } = row; return i2 + r.qty; };
	if (fn() != 10) { throw "GUARD RED: closure rest capture wrong"; }

	const rows: Row[] = [
		{ id: 1, qty: 10, label: "a" },
		{ id: 2, qty: 20, label: "b" },
	];

	// (4) for-of with object rest
	let sum = 0;
	for (const { id: rid, ...r } of rows) {
		if (r.label.length != 1) { throw "GUARD RED: for-of rest string wrong"; }
		sum = sum + rid + r.qty;
	}
	if (sum != 33) { throw "GUARD RED: for-of rest totals wrong"; }

	// (5) for-of with a PLAIN object pattern — no rest involved
	let plain = 0;
	for (const { id: pid, qty } of rows) { plain = plain + pid + qty; }
	if (plain != 33) { throw "GUARD RED: for-of plain object pattern wrong"; }

	console.log("destructureObjectRest ok");
}

main();
