import { Node, NodeKind, ClassDecoratorContext, ClassFieldDecoratorContext } from "std/meta";

let libSeen: int32 = 0;

export function markSeen(): void {
	libSeen = 1;
}

export function seenCount(): int32 {
	return libSeen;
}

export macro tag(value: Node, context: ClassDecoratorContext): void {
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: {
			kind: NodeKind.CallExpr, line: value.line, column: value.column,
			callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "markSeen" },
			arguments: [], isDirectCall: false, resolvedOverloadIdx: -1,
		},
	});
}

export macro plusOne(): (value: Node, context: ClassFieldDecoratorContext) => (init: Node) => Node {
	return (value: Node, context: ClassFieldDecoratorContext): (init: Node) => Node => {
		return (init: Node): Node => ({
			kind: NodeKind.BinaryExpr, line: init.line, column: init.column, operator: "+",
			left: init,
			right: { kind: NodeKind.NumberLiteral, line: init.line, column: init.column, value: 1, isFloat: false },
		});
	};
}

export function touch(value: Node): void {}
