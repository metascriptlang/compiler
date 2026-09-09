// GUARD-JS
// The decorator contract: a field decorator receives (value, context), may
// write context.metadata and return an initializer transformer; a class
// decorator applied afterwards sees that metadata and can addInitializer
// statements that run at module init, using context.name.
//
// A red guard means the context object, the metadata round-trip, the
// initializer transformer, or addInitializer placement drifted.

import { Node, NodeKind, ClassDecoratorContext, ClassFieldDecoratorContext, metadataSet } from "std/meta";

let initRan: int32 = 0;
let metaCount: int32 = 0;
let seenName: string = "";
let seenKind: string = "";

macro tenX(value: Node, context: ClassFieldDecoratorContext): (init: Node) => Node {
	metadataSet(context.metadata, context.name, value);
	return (init: Node): Node => ({
		kind: NodeKind.BinaryExpr, line: init.line, column: init.column, operator: "*",
		left: init,
		right: { kind: NodeKind.NumberLiteral, line: init.line, column: init.column, value: 10, isFloat: false },
	});
}

macro summarize(value: Node, context: ClassDecoratorContext): void {
	const n = context.metadata.keys.length;
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "metaCount" },
			right: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: n, isFloat: false } },
	});
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "initRan" },
			right: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 1, isFloat: false } },
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
}

@summarize
class Meter {
	@tenX a: int32 = 4;
	@tenX b: int32 = 2;
	plain: int32 = 1;
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
	const m = new Meter();
	rc += expect(`${m.a}`, "40", "fieldTransformerA");
	rc += expect(`${m.b}`, "20", "fieldTransformerB");
	rc += expect(`${m.plain}`, "1", "plainField");
	rc += expect(`${metaCount}`, "2", "metadataSharedAcrossDecorators");
	rc += expect(`${initRan}`, "1", "classAddInitializerRan");
	rc += expect(seenName, "Meter", "contextName");
	rc += expect(seenKind, "class", "contextKind");
	if (rc == 0) { console.log("GUARD-OK decoratorContext"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
