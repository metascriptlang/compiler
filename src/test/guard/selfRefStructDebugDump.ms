// selfRefStructDebugDump — dumping a self-referential reference type must
// terminate AND report the data it was given, to full depth.
//
// `console.log(x)` / string-concat lower to a per-type dump function whose
// recursive edge is a CALL, so depth follows the data at runtime instead of
// being fixed when the AST is built. Reference: Nim repr_v2.nim:152 — a single
// generic `repr[T]` guarded by `if isNil(x): return "nil"`, recursing through
// itself. A nil field terminates the walk; a non-nil field does not.
//
// Reachable by design, not by accident: std/meta warns about three such fields
// (Node.nodeTypeAst, Node.typeExpr, FlowNode.antecedent) on every build.
//
// RED pre-fix, two distinct eras:
//   - AST-expansion era: compiler stack overflow (exit 139) building this file.
//   - cycle-guard era: compiled and ran, but a field whose type was already on
//     the expansion path dumped as `null`, so a→b→c printed
//     `Chain { label: "a", next: null }` — a silent lie. That is what the
//     depth assertions below catch.
//
// A NULL reference field is covered too: it used to be dereferenced and die at
// runtime (exit 255). The nil-check is the first statement of every dump
// function, so `null` is now printed rather than followed.

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

class Outer {
	tag: string;
	inner: Chain;
}

function main(): void {
	const c = new Chain();
	c.label = "a";
	c.next = new Chain();
	c.next.label = "b";
	c.next.next = new Chain();
	c.next.next.label = "c";

	const dump = "" + c;
	console.log(dump);
	if (dump.indexOf("\"b\"") < 0) { throw "GUARD RED: chain dump truncated before depth 2: " + dump; }
	if (dump.indexOf("\"c\"") < 0) { throw "GUARD RED: chain dump truncated before depth 3: " + dump; }

	const p = new Ping();
	p.tag = "ping";
	p.other = new Pong();
	p.other.tag = "pong";
	const mutual = "" + p;
	console.log(mutual);
	if (mutual.indexOf("\"pong\"") < 0) { throw "GUARD RED: mutual recursion dropped the far side: " + mutual; }

	const o = new Outer();
	o.tag = "t";
	const nulled = "" + o;
	console.log(nulled);
	if (nulled.indexOf("null") < 0) { throw "GUARD RED: null reference field not reported as null: " + nulled; }

	console.log("selfRefStructDebugDump ok");
}
