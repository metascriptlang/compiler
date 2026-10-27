// @stdout: false true false false true false
// note: `!==` between a nullable and a value inside a macro body calls the std nullable equality, whose parameters are read-only views of `T | null`; the instance must bind T to the compared payload when the prelude comes from the warm pack, not only from a cold build. Variants: a nullable local, a nullable struct field against a string variable, against the head of a split, and a for-of over struct values.

import { Node, NodeKind } from "std/meta";

struct Attr { nativeName: string | null; }

macro localSame(n: Node): Node {
	const x: string | null = n.line > 0 ? "position" : null;
	return { kind: NodeKind.BooleanLiteral, line: n.line, column: n.column, boolValue: x !== "position" };
}

macro localOther(n: Node): Node {
	const x: string | null = n.line > 0 ? "color" : null;
	return { kind: NodeKind.BooleanLiteral, line: n.line, column: n.column, boolValue: x !== "position" };
}

macro structVar(n: Node): Node {
	const a: Attr = { nativeName: "position" };
	const p: string = "position";
	return { kind: NodeKind.BooleanLiteral, line: n.line, column: n.column, boolValue: a.nativeName !== p };
}

macro structSplit(n: Node): Node {
	const a: Attr = { nativeName: "position" };
	return { kind: NodeKind.BooleanLiteral, line: n.line, column: n.column, boolValue: a.nativeName !== "position float32x3 12".split(" ")[0] };
}

macro loopSplit(n: Node): Node {
	const attributes: Attr[] = [{ nativeName: "color" }, { nativeName: "position" }];
	const parts = "position float32x3 12".split(" ");
	let seen = 0;
	for (const a of attributes) {
		if (a.nativeName !== parts[0]) continue;
		seen += 1;
	}
	return { kind: NodeKind.BooleanLiteral, line: n.line, column: n.column, boolValue: seen != 1 };
}

macro nullAgainstValue(n: Node): Node {
	const a: Attr = { nativeName: n.line > 0 ? null : "position" };
	return { kind: NodeKind.BooleanLiteral, line: n.line, column: n.column, boolValue: a.nativeName !== "position" };
}

console.log(`${localSame(1)} ${localOther(1)} ${structVar(1)} ${structSplit(1)} ${nullAgainstValue(1)} ${loopSplit(1)}`);
