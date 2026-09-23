// @xfail(raiser): runs but stdout misses its @stdout line (exit=0)
// @stdout: macro-hoist-generic-recheck PASS
// note: a macro that hoists a `static` prefix, expanded inside an arrow that a GENERIC call checks twice. Once T is bound the checker clears the arrow's state and walks it again, and the second walk meets the arrow AFTER expansion — the value is in place, the prefix is already queued for the enclosing statement list, and the scope that declared it is gone. An expression-bodied arrow died with `Undefined variable 'tpl'`; a block-bodied one compiled, but the clear wiped the prefix's storage class along with the checker flags, so the template was rebuilt on every call. `builds` separates the two outcomes at runtime: one initializer run per SITE, however often the row runs. The non-generic neighbour never re-checks and pins that the fix leaves that path alone. The last shape is the same prefix lost by a different owner: a macro whose OUTPUT holds another macro call inside an array literal. The expander re-expands that call itself and used to flatten the inner SpliceMany into the array — a declaration as an array element. Flattening is the rule for a statement list only; at an expression position the splice travels on as it is and the checker hoists its prefix, whoever produced it. The macro lives in its own module because that is how a component library ships one. Parity C↔JS: expansion happens once in the compile-time VM, so both backends must see the same bound reference.

import { memo, memoInList } from "./memo";

let builds: int32 = 0;

function buildTemplate(): string {
	builds = builds + 1;
	return "T" + builds.toString();
}

function eachRow<T>(p: { each: T[]; row: (n: T) => string }): string {
	return p.row(p.each[0]) + p.row(p.each[0]);
}

function plainRow(p: { each: int32[]; row: (n: int32) => string }): string {
	return p.row(p.each[0]);
}

function viaPlain(): string {
	return plainRow({ each: [1], row: (n) => memo() });
}

function viaGenericExpr(): string {
	return eachRow<int32>({ each: [1], row: (n) => memo() });
}

function viaGenericInferred(): string {
	return eachRow({ each: ["a"], row: (n) => memo() });
}

function viaGenericBlock(): string {
	return eachRow<int32>({ each: [1], row: (n) => { const v = memo(); return v; } });
}

function firstOf(items: string[]): string {
	return items[0];
}

function viaNestedMacro(): string {
	return memoInList();
}

function main(): void {
	let ok = true;

	if (viaPlain() != "T1") ok = false;
	if (viaGenericExpr() != "T2T2") ok = false;
	if (viaGenericExpr() != "T2T2") ok = false;
	if (viaGenericInferred() != "T3T3") ok = false;
	if (viaGenericBlock() != "T4T4") ok = false;
	if (viaGenericBlock() != "T4T4") ok = false;
	if (viaNestedMacro() != "T5") ok = false;
	if (viaNestedMacro() != "T5") ok = false;
	if (builds != 5) ok = false;

	if (ok) {
		console.log("macro-hoist-generic-recheck PASS");
	} else {
		console.log("macro-hoist-generic-recheck FAIL builds=" + builds.toString());
	}
}

main();
