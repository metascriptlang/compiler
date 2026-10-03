import { Node, NodeKind } from "std/meta";

macro exactInteger(node: Node): Node {
	const big: int64 = 9007199254740993;
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: big as number, isFloat: false, intVal: big, outOfRangeText: "", isBitPattern: false };
}

macro sameLiteral(node: Node): Node { return node; }

test "macro literal values: a node built as an integer arrives as that exact integer" {
	const built: uint64 = exactInteger(0);
	assert built == 9007199254740993;
}

test "macro literal values: an integer literal past 2^53 crosses the macro wire exactly" {
	const passed: int64 = sameLiteral(9007199254740993);
	assert passed == 9007199254740993;
}

test "macro literal values: an integral float literal stays a float across the wire" {
	const kept: number = sameLiteral(8.0);
	assert kept == 8.0;
}
