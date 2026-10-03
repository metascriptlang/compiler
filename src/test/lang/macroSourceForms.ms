import { NodeKind, IdentifierData, createNodeAt, makeLoc, Node, childCount, SourceLocation } from "std/meta";
import { declareWireShape } from "./macroWireFixture";

test "macro node variant fit: variant cast widens at a call argument" {
	const loc = makeLoc(1, 1);
	const n = createNodeAt(NodeKind.Identifier, { name: "x" } as IdentifierData, loc);
	assert n.kind == NodeKind.Identifier;
	const d = n.data as IdentifierData;
	assert d.name == "x";
}

test "macro node variant fit: the uncast literal still works" {
	const loc = makeLoc(2, 1);
	const n = createNodeAt(NodeKind.Identifier, { name: "z" }, loc);
	const d = n.data as IdentifierData;
	assert d.name == "z";
}

declareWireShape(0);

test "macro declaration wire: an empty interfaceExtends crosses the macro wire without a Nil walk" {
	const s: WireShape = { a: 5 };
	assert s.a === 5;
}

macro sourceIdentity(node: Node): Node { return node; }

function sourceElement<T>(values: T[], index: int32): T { return sourceIdentity(values[index]); }

macro sourceShape(node: Node): Node {
	let text = "";
	for (const outer of node.elements) {
		if (outer.kind === NodeKind.ArrayLiteral) {
			text = text + "[";
			for (const inner of outer.elements) {
				if (inner.kind !== NodeKind.ObjectLiteral) { error("nested source object required", inner); }
				text = text + childCount(inner).toString();
			}
			text = text + "]";
		} else {
			if (outer.kind !== NodeKind.ObjectLiteral) { error("source object required", outer); }
			text = text + childCount(outer).toString();
		}
	}
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: text };
}

test "macro source forms: generic indexing preserves the selected element" {
	const values: int32[] = [10, 20, 30];
	const words: string[] = ["left", "right"];
	assert sourceElement(values, 0) == 10;
	assert sourceElement(values, 1 + 1) == 30;
	assert sourceElement(words, 1) == "right";
}

test "macro source forms: wrapper stripping recurses without flattening nesting" {
	assert sourceShape([{ width: 1 }, { height: 2 }]) == "11";
	assert sourceShape([[{ width: 1 }], [{ height: 2, depth: 3 }]]) == "[1][2]";
}

function dbl(value: string): string { return "caller " + value; }

function inner(value: string): string { return "caller macro " + value; }

test "macro expansion identity: declaration-module symbols resist caller shadowing" {
	assert dbl("x") == "caller x";
	assert inner("y") == "caller macro y";
}

function triple(value: int32): int32 { return value * 3; }

macro tripled(node: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: node.line,
		column: node.column,
		callee: bindSym("triple"),
		arguments: [node],
	};
}

test "macro expansion identity: a same-module bound callee resists a block-local shadow" {
	assert tripled(14) == 42;
	{ const triple: int32 = 9; assert tripled(8) + triple == 33; }
}

function nodeLeaf(loc: SourceLocation): Node {
	return createNodeAt(NodeKind.NumberLiteral, { value: 42, isFloat: false, intVal: 42 as int64 }, loc);
}

function nodeBranch(loc: SourceLocation): Node { return nodeLeaf(loc); }

macro helperOperands(node: Node): Node {
	const loc: SourceLocation = { line: node.line, column: node.column };
	return { kind: NodeKind.BinaryExpr, line: node.line, column: node.column, operator: "+", left: nodeLeaf(loc), right: nodeLeaf(loc) };
}

macro sharedOperand(node: Node): Node {
	const loc: SourceLocation = { line: node.line, column: node.column };
	const operand = nodeLeaf(loc);
	return { kind: NodeKind.BinaryExpr, line: node.line, column: node.column, operator: "+", left: operand, right: operand };
}

macro transitiveOperands(node: Node): Node {
	const loc: SourceLocation = { line: node.line, column: node.column };
	return { kind: NodeKind.BinaryExpr, line: node.line, column: node.column, operator: "+", left: nodeBranch(loc), right: nodeBranch(loc) };
}

test "macro source forms: helper-built nodes retain operands across storage and call depth" {
	assert helperOperands(0) == 84;
	assert sharedOperand(0) == 84;
	assert transitiveOperands(0) == 84;
}
