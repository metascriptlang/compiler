// @stdout: true false true false true false
// note: `==` on a struct or a tuple inside a macro body instantiates the std value equality, whose body expands a std macro while the engine is still compiling the outer macro. The nested compile joins the running engine instead of replacing it; replacing it freed the image under the outer compile (exit 139). Variants: struct, tuple, and a helper the engine compiles on demand.

import { Node, NodeKind } from "std/meta";

struct P { x: int32; tag: string; }

function samePoint(a: P, b: P): boolean {
	return a == b;
}

macro structEq(): Node {
	const a: P = { x: 1, tag: "m" };
	const b: P = { x: 1, tag: "m" };
	return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: a == b };
}

macro structNe(): Node {
	const a: P = { x: 1, tag: "m" };
	const b: P = { x: 1, tag: "n" };
	return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: a == b };
}

macro tupleEq(): Node {
	const l: [int32, string] = [1, "a"];
	const r: [int32, string] = [1, "a"];
	return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: l == r };
}

macro tupleNe(): Node {
	const l: [int32, string] = [1, "a"];
	const r: [int32, string] = [2, "a"];
	return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: l == r };
}

macro helperEq(): Node {
	return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: samePoint({ x: 3, tag: "h" }, { x: 3, tag: "h" }) };
}

macro helperNe(): Node {
	return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: samePoint({ x: 3, tag: "h" }, { x: 4, tag: "h" }) };
}

console.log(`${structEq()} ${structNe()} ${tupleEq()} ${tupleNe()} ${helperEq()} ${helperNe()}`);
