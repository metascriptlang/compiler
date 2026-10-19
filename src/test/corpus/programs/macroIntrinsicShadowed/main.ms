// @stdout: e:boom s:2 c:7 t:int 6 | 10 11 5 | 9 named
// note: inside a macro body, `error`, `splice`, `createNodeAt` and `getTypeArg` are the std/meta intrinsics only when the name resolves to std/meta's declaration, imported or left to the macro prelude (also where the program prelude declares the same name, as std's array `splice`); a module's own functions spelled the same are ordinary calls, and a quote's `${ }` splices whatever `splice` names. Same output on every backend.
import { Node, NodeKind } from "std/meta";
import { doubled, bumped, checked } from "./std";
import { kindOf, plusOne } from "./implicit";

interface Part { n: int32; }

function error(msg: string): string { return "e:" + msg; }
function splice(n: int32): string { return "s:" + n.toString(); }
function createNodeAt(k: int32, d: Part, at: int32): string { return "c:" + (k + d.n + at).toString(); }
function getTypeArg(): string { return "t:int"; }

macro own(e: Node): Node {
	error("a statement call is still the module's error");
	const v = error("boom") + " " + splice(2) + " " + createNodeAt(1, { n: 2 }, 4) + " " + getTypeArg();
	return { kind: NodeKind.StringLiteral, line: e.line, column: e.column, value: v };
}

macro twice(x: Node): Node {
	return quote { ${x} + ${x} };
}

console.log(`${own(0)} ${twice(3)} | ${doubled(5)} ${bumped(10)} ${plusOne(4)} | ${checked(9)} ${kindOf<int32>()}`);
