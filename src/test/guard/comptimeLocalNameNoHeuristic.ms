// comptimeLocalNameNoHeuristic — a comptime local's type comes from the type
// system, never from its NAME (Nim vmgen model: genVarSection asserts
// s.typ != nil; a missing type is an internal error, not a hint).
//
// typeRefine.ms once carried desperationHeuristic(): after resolvedSym →
// scope → registry all missed, it mapped the identifier's SPELLING to a type
// ("elem"/"node"/"expr"/... → Node, *Type → Type, *Sym → Symbol). A comptime
// string local named `elem` used in an assignment became a Node, string-concat
// lowered it through buildStructToString on the self-referential Node struct,
// and wrapFieldAsJson ⇄ buildNestedJsonObject recursed until SIGSEGV. The
// assignment shape (`out = out + elem`, not just `let out = ... + elem`) is
// load-bearing: single-assignment concat never lost the type.
//
// RED pre-fix: compiler stack overflow (exit 139) building this file.

import { Node, NodeKind } from "std/meta";

macro nameProbe(tag: Node): Node {
	let out = "";
	let elem = "plain";
	let node = "n";
	let expr = "e";
	let fooType = "t";
	out = out + elem + ":" + node + ":" + expr + ":" + fooType;
	return { kind: NodeKind.StringLiteral, line: tag.line, column: tag.column, value: out };
}

function main(): void {
	const got = nameProbe(0);
	console.log(got == "plain:n:e:t" ? "names:ok" : "names:RED " + got);
	console.log("comptimeLocalNameNoHeuristic ok");
}

main();
