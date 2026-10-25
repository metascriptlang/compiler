// @stdout: Cc?n|C|91 1|91 1|6
// note: a NodeKind or DeclKind member read in a macro body, a comptime function or a helper in
// another module evaluates to the member's value through its resolved symbol, for the last
// NodeKind member as for the others: as a match arm, a stored value, a cross-module compare and
// the kind of a node built inside a for..of body.
import { Node, NodeKind, DeclKind } from "std/meta";
import { isComputed } from "./kinds";

const screen = { wide: 900, narrow: 400 };

@comptime function isComputedKind(k: int32): boolean {
	return k == (NodeKind.ComputedProperty as int32);
}

macro classify(v: Node): Node {
	let s = "";
	for (const p of v.properties) {
		const label = match (p.kind) {
			NodeKind.ComputedProperty => "C",
			NodeKind.ObjectLiteral => "O",
			_ => "?",
		};
		s = s + label + (isComputedKind(p.kind as int32) ? "c" : "n");
	}
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: s };
}

macro firstComputed(v: Node): Node {
	const s = isComputed(v.properties[0]) ? "C" : "-";
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: s };
}

macro stored(v: Node): Node {
	const k = NodeKind.ComputedProperty;
	const d = DeclKind.Let;
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: `${k as int32} ${d as int32}` };
}

macro summed(v: Node): Node {
	const parts: Node[] = [];
	let n = 0;
	for (const e of v.elements) {
		n += 1;
		parts.push({ kind: NodeKind.NumberLiteral, line: e.line, column: e.column, value: n * 2 });
	}
	return { kind: NodeKind.BinaryExpr, line: v.line, column: v.column, operator: "+", left: parts[0], right: parts[1] };
}

const classified = classify({ [screen.wide]: { width: 280 }, plain: 1 });
const first = firstComputed({ [screen.narrow]: 1 });
const expected = `${NodeKind.ComputedProperty as int32} ${DeclKind.Let as int32}`;
console.log(classified + "|" + first + "|" + stored(0) + "|" + expected + "|" + summed([1, 2]));
