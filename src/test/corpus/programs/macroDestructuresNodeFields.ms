// @stdout: 15:16 width@15 1
import { Node, NodeKind } from "std/meta";

macro at(value: Node): Node {
	const { line, column } = value;
	return { kind: NodeKind.StringLiteral, line, column, value: `${line}:${column}` };
}

macro nameOf(id: Node): Node {
	const { name, line } = id;
	return { kind: NodeKind.StringLiteral, line, column: 0, value: `${name}@${line}` };
}

const width = 1;
console.log(at("x"), nameOf(width), width);
