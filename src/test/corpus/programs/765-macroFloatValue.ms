// Parity program — a float literal handed to a macro keeps its fraction:
// `floatValue(v)` reads it back through the host bridge, and a NumberLiteral
// built from it expands to the same value the runtime prints.
//
// @stdout: 0.5|0.5|float
// @exit: 0

import { Node, NodeKind, isFloatLiteral, floatValue } from "std/meta";

macro fstr(v: Node): Node {
	const f = floatValue(v);
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: f.toString() + "|" + (isFloatLiteral(v) ? "float" : "int") };
}

macro fnum(v: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: v.line, column: v.column, value: floatValue(v), isFloat: true };
}

console.log(fnum(0.5).toString() + "|" + fstr(0.5));
