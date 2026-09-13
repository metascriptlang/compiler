// A Node literal nested inside another Node literal is checked to the same
// depth as the outermost one: the node under `expr`, and the node under that
// node's `callee`, are Nodes, so a key that exists on no NodeData variant is
// rejected two levels down.
//
// A red guard means the expected type stopped reaching past the outermost
// literal, and a typo'd field in a built call silently expands to garbage —
// the shape that let `args` sit unnoticed in a decorator for months.
//
// GUARD-CHECK-FAIL decorator 'tagged':
// GUARD-CHECK-FAIL 'bogusKid' does not exist in type 'Node'

import { Node, NodeKind, ClassDecoratorContext } from "std/meta";

function bump(): void { }

macro tagged(value: Node, context: ClassDecoratorContext): Node {
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: {
			kind: NodeKind.CallExpr, line: value.line, column: value.column,
			callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "bump", bogusKid: 1 },
			arguments: [],
		},
	});
	return value;
}

@tagged
class Marked {
	base: int32 = 1;
}

function main(): int32 {
	return new Marked().base - 1;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
