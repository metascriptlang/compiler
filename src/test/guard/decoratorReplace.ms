// GUARD-JS
// The remaining decorator contract paths: same-kind replacement (a method and
// a field decorator that return the declaration back), a factory macro whose
// closure returns an initializer transformer, context.access building a
// `this.x` read/write that addInitializer places in the constructor after the
// field initializers, and a static-member initializer that lands at module init.
//
// A red guard means one of those wiring paths drifted.

import { Node, NodeKind, ClassMethodDecoratorContext, ClassFieldDecoratorContext } from "std/meta";

let staticSeen: int32 = 0;

macro keep(value: Node, context: ClassMethodDecoratorContext): Node {
	return value;
}

macro keepField(value: Node, context: ClassFieldDecoratorContext): Node {
	return value;
}

macro scale(n: int32): (value: Node, context: ClassFieldDecoratorContext) => (init: Node) => Node {
	return (value: Node, context: ClassFieldDecoratorContext): (init: Node) => Node => {
		return (init: Node): Node => ({
			kind: NodeKind.BinaryExpr, line: init.line, column: init.column, operator: "*",
			left: init,
			right: { kind: NodeKind.NumberLiteral, line: init.line, column: init.column, value: n, isFloat: false },
		});
	};
}

macro bump(value: Node, context: ClassFieldDecoratorContext): void {
	const self: Node = { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "this" };
	const plusOne: Node = {
		kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "+",
		left: context.access.get(self),
		right: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 1, isFloat: false },
	};
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: context.access.set(self, plusOne) });
}

macro markStatic(value: Node, context: ClassMethodDecoratorContext): void {
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "staticSeen" },
			right: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: context.static ? 1 : 2, isFloat: false } },
	});
}

class Gauge {
	@keepField base: int32 = 7;
	@scale(3) tripled: int32 = 5;
	@bump counter: int32 = 5;

	@keep total(): int32 { return this.base + this.tripled + this.counter; }

	@markStatic static ping(): int32 { return 1; }
}

function expect(actual: string, want: string, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

function main(): int32 {
	let rc: int32 = 0;
	const g = new Gauge();
	rc += expect(`${g.base}`, "7", "fieldReturnedBack");
	rc += expect(`${g.tripled}`, "15", "factoryTransformer");
	rc += expect(`${g.counter}`, "6", "accessSetInConstructor");
	rc += expect(`${g.total()}`, "28", "methodReturnedBack");
	rc += expect(`${Gauge.ping()}`, "1", "staticMethodIntact");
	rc += expect(`${staticSeen}`, "1", "staticInitializerAndContextStatic");
	if (rc == 0) { console.log("GUARD-OK decoratorReplace"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
