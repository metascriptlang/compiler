// macroConstObjectRefused — a module-level const that holds an object FAILS LOUD in macro-time code.
//
// The VM compiles a const through its initializer at every use, so a Map, a Set, an
// array or a class instance would be a new object at each read: a write through one use
// is lost to the next. Reading such a const refuses instead of inlining it.
//
// GUARD-CHECK-FAIL a module-level const of type

import { Node, NodeKind } from "std/meta";

const SEEN: Map<string, int32> = new Map();
const LOG: string[] = [];

function remember(k: string): int32 {
	SEEN.set(k, 1); // GUARD-REFUSED
	return 1;
}

function note(k: string): int32 {
	LOG.push(k); // GUARD-REFUSED
	return LOG.length;
}

export macro mMap(n: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: remember("a") };
}

export macro mArray(n: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: note("a") };
}

function main(): void {
	console.log(mMap(<p class="box">hi</p>));
	console.log(mArray(<p class="box">hi</p>));
}
main();
