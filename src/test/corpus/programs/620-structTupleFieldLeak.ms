// @maxrss: 40
// @stdout: struct-tuple-field done acc=0
// note: FIXED (companion to map-tuple-value-leak): a heap interface/struct with a tuple field hit two tuple-not-first-class holes at once — (1) BUILD FAIL: the auto-generated HolderEq compared the `pair` field with C `===` on a struct value (`invalid operands to binary expression 'msTuple_lta21p'`) because destructorLifting fieldEqExpr had no Tuple case; now routes to the generated msTuple_<hash>Eq via ensureTupleEq (sharing the operatorLower pending-ops dedup key); (2) LEAK: without named tuple hooks the field's heap strings leaked per drop. Both fixed by the first-class tuple work. Builds + flat ~2.2MB drc+orc.

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
