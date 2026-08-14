// selfRefStructDebugDump — dumping a self-referential reference type must
// terminate. `console.log(x)` lowers to jsonObject(keys, vals) via
// buildNestedJsonObject; each struct-typed field recurses back through
// wrapFieldAsJson, so a type reachable from itself expanded forever and the
// COMPILER died with a stack overflow (exit 139) — no diagnostic, no location.
//
// Reachable by design, not by accident: std/meta warns about three such fields
// (Node.nodeTypeAst, Node.typeExpr, FlowNode.antecedent) on every build.
//
// The guard is the type-name path currently being expanded; a field whose type
// is already on that path dumps as null. Mutual recursion (A→B→A) and the
// depth cap are covered too — a cap alone would still expand 2^depth nodes for
// a wide type, and a visited-set alone cannot stop an anonymous struct.
//
// RED pre-fix: compiler stack overflow building this file.
//
// Nested fields are populated on purpose: dumping a reference-type field that
// is NULL dereferences it and dies at runtime (exit 255) — a separate,
// pre-existing hole, reproducible with no cycle anywhere.

class Chain {
	label: string;
	next: Chain;
}

class Ping {
	tag: string;
	other: Pong;
}

class Pong {
	tag: string;
	back: Ping;
}

function main(): void {
	const c = new Chain();
	c.label = "head";
	console.log(c);

	const p = new Ping();
	p.tag = "ping";
	p.other = new Pong();
	p.other.tag = "pong";
	console.log(p);

	console.log("selfRefStructDebugDump ok");
}
