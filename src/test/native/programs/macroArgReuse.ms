// Stage A gate: a macro compiled ONCE is re-invoked with DIFFERENT args, each
// arg flowing through registers (not const-baked). If the compile-once cache or
// the arg→register marshalling were wrong, the second invocation would reuse the
// first's arg (or corrupt) and the assertion would surface a wrong number.

import { Node, NodeKind } from "std/meta";

macro dbl(a: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: a.line, column: a.column, value: a.value * 2, isFloat: false };
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
