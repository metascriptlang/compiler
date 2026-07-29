// @maxrss: 30
// @stdout: macro-arg-reuse PASS
// @skip-js: migrated from native/ — JS-lane audit pending
// note: Stage A compile-once cache + args-in-registers. A macro compiled once (getOrCompileMacro, cached on CheckerContext identity) is re-invoked with different args — dbl(5)→10, dbl(21)→42 — each arg marshalled via nodeToValue into the callee's registers and re-entered through vmCallFunction, replacing the old per-invocation const-baking (const p = <arg literal>) + full recompile. If the cache reuse were unsound the second call would reuse the first's arg; if the reused VM's heap weren't reset between calls the marshalled arg would alias stale objects. Either surfaces as a wrong number in the assertion.

// Stage A gate: a macro compiled ONCE is re-invoked with DIFFERENT args, each
// arg flowing through registers (not const-baked). If the compile-once cache or
// the arg→register marshalling were wrong, the second invocation would reuse the
// first's arg (or corrupt) and the assertion would surface a wrong number.

import { Node, NodeKind, NumberLiteralData } from "std/meta";

macro dbl(a: Node): Node {
	const ad = a.data as NumberLiteralData;
	return { kind: NodeKind.NumberLiteral, line: a.line, column: a.column, value: ad.value * 2, isFloat: false };
}

function main(): void {
	const x: number = dbl(5);   // → 10
	const y: number = dbl(21);  // → 42
	if (x === 10 && y === 42) {
		console.log("macro-arg-reuse PASS");
	} else {
		console.log("macro-arg-reuse FAIL x=" + x.toString() + " y=" + y.toString());
	}
}
main();
