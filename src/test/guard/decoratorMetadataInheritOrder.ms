// A subclass declared BEFORE its parent still inherits the parent's decorator
// metadata: the parent's decorators are applied on demand when the subclass
// asks for them, so the answer does not depend on declaration order.
//
// No GUARD-JS directive on purpose. The JS backend emits classes in source
// order and JavaScript's temporal dead zone rejects a subclass whose parent is
// defined later — measured identical on a decorator-free program built by the
// same compiler, so it is a backend property, not a decorator one.
//
// A red guard means the on-demand parent apply drifted back to source order.

import { Node, NodeKind, ClassDecoratorContext, metadataSet, metadataGet } from "std/meta";

let rA: int32 = -1;

macro tagA1(value: Node, context: ClassDecoratorContext): void {
	metadataSet(context.metadata, "a", {
		kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 1, isFloat: false,
	});
}

macro probeR(value: Node, context: ClassDecoratorContext): void {
	let read: Node = { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 0, isFloat: false };
	const found = metadataGet(context.metadata, "a");
	if (found != null) read = found;
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "rA" },
			right: read },
	});
}

@probeR
class RK extends RP { y: int32 = 2; }

@tagA1
class RP { x: int32 = 1; }

function expect(actual: string, want: string, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

function main(): int32 {
	let rc: int32 = 0;
	const rk = new RK();
	rc += expect(`${rk.x}`, "1", "reverseOrderFieldsSurvive");
	rc += expect(`${rk.y}`, "2", "reverseOrderOwnFieldSurvives");
	rc += expect(`${rA}`, "1", "parentDeclaredAfterSubclass");
	if (rc == 0) { console.log("GUARD-OK decoratorMetadataInheritOrder"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
