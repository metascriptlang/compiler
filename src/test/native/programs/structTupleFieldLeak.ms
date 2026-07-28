// Guards a heap struct/interface with a tuple field — two distinct tuple-not-first-class
// holes surfaced together: (1) the auto-generated HolderEq compared the `pair` field with
// C `===` on a struct value (`invalid operands to binary expression 'msTuple_lta21p'`),
// because fieldEqExpr had no Tuple case — it now routes to the generated msTuple_<hash>Eq;
// (2) without named tuple hooks the field's heap strings leaked on every drop (same root as
// map-tuple-value-leak). Fix: fieldEqExpr Tuple case + ensureTupleEq, plus the first-class
// tuple DRC hooks. Builds + flat ~2.2MB drc+orc.

interface Holder { pair: [string, string]; tag: int32; }

function big(seed: number): string {
	let s = "x";
	for (let i = 0; i < 10; i = i + 1) { s = s + s; }
	return s;
}

function main(): void {
	let acc = 0;
	for (let n = 0; n < 200000; n = n + 1) {
		const h: Holder = { pair: [big(n), big(n + 1)], tag: n as int32 };
		acc = (acc + h.tag) % 1000;
	}
	console.log(`struct-tuple-field done acc=${acc}`);
}
main();
