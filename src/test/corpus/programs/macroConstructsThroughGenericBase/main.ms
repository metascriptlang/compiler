// note: a macro body builds a class whose constructor reaches a generic base through super, as it
// builds one over a plain base; a typed array is such a class. Same output on every lane.
// @stdout: plain=2 generic=3 bytes=4
// @exit: 0
import { Node, NodeKind } from "std/meta";
import { Sub, GSub } from "./lib";

macro plain(at: Node): Node {
	return { kind: NodeKind.StringLiteral, line: at.line, column: at.column, value: "plain=" + new Sub(1).n.toString() };
}

macro generic(at: Node): Node {
	return { kind: NodeKind.StringLiteral, line: at.line, column: at.column, value: "generic=" + new GSub(1).n.toString() };
}

macro bytes(at: Node): Node {
	return { kind: NodeKind.StringLiteral, line: at.line, column: at.column, value: "bytes=" + new Uint8Array(4).length.toString() };
}

console.log(plain(0), generic(0), bytes(0));
