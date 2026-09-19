// GUARD-JS
// A class declared inside a function body records its decorators on its own
// symbol, exactly as a module-level class does: the field decorators read back
// through the type, and a field decorator on a nested subclass still reads the
// metadata its nested parent wrote.
//
// A red guard means the nested declaration path lost the symbol that carries
// the record, or applied the decorators before minting it.

import { Node, NodeKind, ClassDecoratorContext, ClassFieldDecoratorContext, metadataSet, metadataGet } from "std/meta";

let nFieldA: int32 = -1;

function rename(name: string): (value: Node) => void {
	return (value: Node): void => {};
}

macro tagA1(value: Node, context: ClassDecoratorContext): void {
	metadataSet(context.metadata, "a", {
		kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 1, isFloat: false,
	});
}

macro probeField(value: Node, context: ClassFieldDecoratorContext): void {
	let read: Node = { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 0, isFloat: false };
	const found = metadataGet(context.metadata, "a");
	if (found != null) read = found;
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "nFieldA" },
			right: read },
	});
}

macro decoratedFieldCount(x: Node): Node {
	let t = x.nodeType;
	if (t.kind == NodeKind.TypeGeneric) t = t.typExprArgs[0];
	const decs = t.typExprFieldDecorators;
	if (decs.length != 2) error("expected 2 field slots, got " + decs.length, x);
	if (decs[1].length != 0) error("expected no decorator on the second field", x);
	if (decs[0].length == 1 && decs[0][0].macroName != "rename") error("the first field is not decorated by rename", x);
	return { kind: NodeKind.NumberLiteral, line: x.line, column: x.column, value: decs[0].length, isFloat: false };
}

class TopDoc {
	@rename("_id") id: string = "";
	name: string = "";
}

function inFunction(): int32 {
	class FnDoc {
		@rename("_id") id: string = "";
		name: string = "";
	}
	const d: FnDoc = new FnDoc();
	return decoratedFieldCount(d);
}

function inBlock(): int32 {
	let r: int32 = 0;
	{
		class BlockDoc {
			@rename("_id") id: string = "";
			name: string = "";
		}
		const d: BlockDoc = new BlockDoc();
		r = decoratedFieldCount(d);
	}
	return r;
}

class Holder {
	build(): int32 {
		class MethDoc {
			@rename("_id") id: string = "";
			name: string = "";
		}
		const d: MethDoc = new MethDoc();
		return decoratedFieldCount(d);
	}
}

function nestedChain(): int32 {
	@tagA1
	class NP { x: int32 = 1; }
	class NK extends NP {
		@probeField f: int32 = 0;
	}
	const k = new NK();
	return k.x + k.f;
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
	const t: TopDoc = new TopDoc();
	rc += expect(`${decoratedFieldCount(t)}`, "1", "topLevelFieldDecoratorRecorded");
	rc += expect(`${inFunction()}`, "1", "functionLocalFieldDecoratorRecorded");
	rc += expect(`${inBlock()}`, "1", "blockLocalFieldDecoratorRecorded");
	rc += expect(`${new Holder().build()}`, "1", "methodLocalFieldDecoratorRecorded");
	rc += expect(`${nestedChain()}`, "1", "nestedSubclassFieldsSurvive");
	rc += expect(`${nFieldA}`, "1", "nestedFieldDecoratorReadsParentMetadata");
	if (rc == 0) { console.log("GUARD-OK decoratorNestedRecord"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
