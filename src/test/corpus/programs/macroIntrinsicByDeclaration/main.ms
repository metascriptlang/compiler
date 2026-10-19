// @stdout: own:x mine:y | std:expanded std:bound | 21
// note: inside a macro body, `bindSym` and `getTypeImpl` are the std/meta intrinsics when the name resolves to std/meta's declaration, imported or left to the macro prelude; a module's own functions spelled the same are ordinary calls. Same output on every backend.
import { Node, NodeKind } from "std/meta";
import { probe } from "./std";
import { implicitBind } from "./implicit";

function getTypeImpl(label: string): string { return "own:" + label; }
function bindSym(name: string): string { return "mine:" + name; }

macro own(e: Node): Node {
	const who = "x";
	const a = getTypeImpl(who);
	const b = bindSym("y");
	return { kind: NodeKind.StringLiteral, line: e.line, column: e.column, value: a + " " + b };
}

console.log(`${own(0)} | ${probe(0)} | ${implicitBind(7)}`);
