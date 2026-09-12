// An actor takes decorators like a class: a class-level decorator receives the
// actor declaration with context.kind "class", may add a field to the actor
// body, and its addInitializer statements run once the actor is defined; a
// member decorator on an actor field still transforms the initializer.
//
// A red guard means actor declarations fell out of the decorator positions.

import { Node, NodeKind, ClassDecoratorContext, ClassFieldDecoratorContext } from "std/meta";

let seenName: string = "";
let seenKind: string = "";

macro withExtra(value: Node, context: ClassDecoratorContext): Node {
	value.actorBody.push({
		kind: NodeKind.PropertyDecl, line: value.line, column: value.column,
		propName: "extra", propType: "int32", propIsStatic: false, propIsReadonly: false,
		propVisibility: "public",
		propInitializer: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 41, isFloat: false },
	});
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "seenName" },
			right: { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: context.name } },
	});
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "seenKind" },
			right: { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: context.kind } },
	});
	return value;
}

macro twice(value: Node, context: ClassFieldDecoratorContext): Node {
	const init = value.propInitializer;
	value.propInitializer = {
		kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "*",
		left: init,
		right: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 2, isFloat: false },
	};
	return value;
}

@withExtra
actor Counter {
	@twice base: int32 = 1;
	total(): int32 { return this.base + this.extra; }
}

function expect(actual: string, want: string, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

async function main(): Promise<int32> {
	let rc: int32 = 0;
	const c = new Counter();
	const total = await c.total();
	rc += expect(`${total}`, "43", "actorFieldAddedAndDoubled");
	rc += expect(seenName, "Counter", "contextName");
	rc += expect(seenKind, "class", "contextKind");
	if (rc == 0) { console.log("GUARD-OK decoratorActor"); }
	return rc;
}

const rc = await main();
if (rc != 0) { process.exit(rc); }
