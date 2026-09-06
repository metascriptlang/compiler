// macroChildIndexTraversal — std/meta childCount/childAt walk a Node's
// children BY INDEX from a TOP-LEVEL helper (the Nim n[i]/n.len analog).
//
// Flat field names (n.left, n.object, ...) resolve only inside engine-mode
// checks, so before these accessors a helper shared between two macros could
// not exist at top level and every macro duplicated its walker (Neon's
// isReactive classifier). The accessors ride the same extern→CallHost route
// as every std native; the bridges (msNodeChildCount/At, hostTable.ms)
// dereference the flat VM wire through the active-VM heaps.
//
// RED pre-fix: "'childCount' is not exported from 'std/meta'".
// The ternary stays OUTSIDE the quote on purpose — quote { splice(b) ? 1 : 0 }
// is a separate pre-existing expansion bug (nil result).

import { Node, NodeKind, childCount, childAt } from "std/meta";

function containsCall(n: Node): boolean {
	if (n == null) return false;
	if (n.kind == NodeKind.CallExpr) return true;
	if (n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr) return false;
	const c = childCount(n);
	for (let i = 0; i < c; i = i + 1) {
		if (containsCall(childAt(n, i))) return true;
	}
	return false;
}

macro reactiveFlag(e: Node): Node {
	const v = containsCall(e) ? 1 : 0;
	return quote { splice(v) };
}

// metaSolo pins the metadata exclusion: a checked identifier carries
// resolvedSym + nodeType (+ symHandle when BoundSym) on the wire, and
// resolvedSym/nodeType are node-shaped — a broken isNodeWireMetaField
// (wire.ms) would count them as children.
macro kidCount(e: Node): Node {
	const v = childCount(e);
	return quote { splice(v) };
}

function f(): number { return 3; }
const gate = true;

function main(): void {
	const plain = reactiveFlag(1 + 2);
	const direct = reactiveFlag(f() + 1);
	const inArray = reactiveFlag([1, f(), 3]);
	const inTernary = reactiveFlag(gate ? f() : 1);
	const behindArrow = reactiveFlag(() => f());
	console.log(plain == 0 ? "plain:ok" : "plain:RED");
	console.log(direct == 1 ? "direct:ok" : "direct:RED");
	console.log(inArray == 1 ? "inArray:ok" : "inArray:RED");
	console.log(inTernary == 1 ? "inTernary:ok" : "inTernary:RED");
	console.log(behindArrow == 0 ? "behindArrow:ok" : "behindArrow:RED");
	const metaSolo = kidCount(f);
	const callKids = kidCount(f());
	console.log(metaSolo == 0 ? "metaSolo:ok" : "metaSolo:RED");
	console.log(callKids == 1 ? "callKids:ok" : "callKids:RED");
	if (plain != 0) { throw "GUARD RED: static expr classified reactive"; }
	if (direct != 1) { throw "GUARD RED: call in binary expr missed"; }
	if (inArray != 1) { throw "GUARD RED: call inside array literal missed"; }
	if (inTernary != 1) { throw "GUARD RED: call inside ternary missed"; }
	if (behindArrow != 0) { throw "GUARD RED: arrow boundary not respected"; }
	if (metaSolo != 0) { throw "GUARD RED: metadata field counted as child"; }
	if (callKids != 1) { throw "GUARD RED: callee child missed"; }
	console.log("macroChildIndexTraversal ok");
}
main();
