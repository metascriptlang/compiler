// macroConstObjectRefused — macro-time code that writes to an object held by a module-level const FAILS LOUD.
//
// The VM compiles a const through its initializer at every use, so a Map, a Set or a class
// instance would be a new object at each read, and a write through a const array would never
// reach the next read. A const class instance is refused on any use; a const array is refused
// on a write (assignment, update, push and the other mutating array methods) and read freely.
//
// GUARD-CHECK-FAIL a module-level const of type
// GUARD-CHECK-FAIL a write through a module-level const array

import { Node, NodeKind } from "std/meta";

const SEEN: Map<string, int32> = new Map();
const LOG: string[] = [];

function remember(k: string): int32 {
	return SEEN.has(k) ? 1 : 0; // GUARD-REFUSED
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
