// GUARD-JS
// Decorator metadata resolves through the class chain: a subclass reads what
// its parent's decorators wrote, `keys` still lists only what the class itself
// wrote, the nearest class wins a duplicate key, and the chain answers the same
// way whether the subclass carries only a field decorator or lives inside a
// function body. Declaration order is pinned separately in
// decoratorMetadataInheritOrder, which the JS backend cannot express.
//
// A red guard means the chain walk or the own/inherited split drifted.

import { Node, NodeKind, ClassDecoratorContext, ClassFieldDecoratorContext, metadataSet, metadataGet } from "std/meta";

let gOwn: int32 = -1;
let gA: int32 = -1;
let gB: int32 = -1;
let fFieldA: int32 = -1;
let nA: int32 = -1;

macro tagA1(value: Node, context: ClassDecoratorContext): void {
	metadataSet(context.metadata, "a", {
		kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 1, isFloat: false,
	});
}

macro tagA9(value: Node, context: ClassDecoratorContext): void {
	metadataSet(context.metadata, "a", {
		kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 9, isFloat: false,
	});
}

macro tagB2(value: Node, context: ClassDecoratorContext): void {
	metadataSet(context.metadata, "b", {
		kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 2, isFloat: false,
	});
}

macro probeG(value: Node, context: ClassDecoratorContext): void {
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "gOwn" },
			right: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: context.metadata.keys.length, isFloat: false } },
	});
	let readA: Node = { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 0, isFloat: false };
	const foundA = metadataGet(context.metadata, "a");
	if (foundA != null) readA = foundA;
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "gA" },
			right: readA },
	});
	let readB: Node = { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 0, isFloat: false };
	const foundB = metadataGet(context.metadata, "b");
	if (foundB != null) readB = foundB;
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "gB" },
			right: readB },
	});
}

macro probeField(value: Node, context: ClassFieldDecoratorContext): void {
	let read: Node = { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 0, isFloat: false };
	const found = metadataGet(context.metadata, "a");
	if (found != null) read = found;
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "fFieldA" },
			right: read },
	});
}

macro probeN(value: Node, context: ClassDecoratorContext): void {
	let read: Node = { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 0, isFloat: false };
	const found = metadataGet(context.metadata, "a");
	if (found != null) read = found;
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "nA" },
			right: read },
	});
}

@tagA1
class P { x: int32 = 1; }

@tagA9
@tagB2
class K extends P { y: int32 = 2; }

@probeG
class G extends K { z: int32 = 3; }

@tagA1
class FP { x: int32 = 1; }

class FK extends FP {
	@probeField f: int32 = 0;
}

function nestedBuild(): int32 {
	@tagA1
	class NP { x: int32 = 1; }
	@probeN
	class NK extends NP { y: int32 = 2; }
	const n = new NK();
	return n.x + n.y;
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
	const g = new G();
	const fk = new FK();
	const sum = nestedBuild();
	rc += expect(`${g.x}`, "1", "chainFieldsSurvive");
	rc += expect(`${fk.f}`, "0", "fieldDecoratorKeepsInit");
	rc += expect(`${sum}`, "3", "nestedFieldsSurvive");
	rc += expect(`${gOwn}`, "0", "inheritedKeysAreNotOwnKeys");
	rc += expect(`${gA}`, "9", "nearestClassWinsDuplicateKey");
	rc += expect(`${gB}`, "2", "twoLevelChainRead");
	rc += expect(`${fFieldA}`, "1", "fieldDecoratorReadsParentMetadata");
	rc += expect(`${nA}`, "1", "nestedChainRead");
	if (rc == 0) { console.log("GUARD-OK decoratorMetadataInherit"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
