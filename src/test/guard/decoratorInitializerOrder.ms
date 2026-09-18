// GUARD-JS
// addInitializer statements run where tsc runs them: a method's initializer
// before the first field initializer, a field's initializer right after that
// field's own value is set, all of it after super() and before the constructor
// body. Measured against tsc 5.x (es2022 and es2015 agree). The class also
// carries a class decorator that returns it, so the members the initializers
// belong to are the copy the decorator handed back.
//
// A red guard means an initializer drifted relative to the field initializers.
//
// The static half runs at module init, in class-body order: a static method's
// initializer first, then each static field's value followed by that field's
// own initializers, then the class initializer.

import { Node, NodeKind, ClassDecoratorContext, ClassMethodDecoratorContext, ClassFieldDecoratorContext } from "std/meta";

let trace: string = "";
function mark(s: string): int32 { trace = trace + s + ","; return 1; }

macro onMethod(value: Node, context: ClassMethodDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "mark" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "m-init" } ] } });
	return value;
}
macro onFieldB(value: Node, context: ClassFieldDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "mark" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "fb-extra" } ] } });
	return value;
}
macro onFieldC(value: Node, context: ClassFieldDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "mark" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "fc-extra" } ] } });
	return value;
}
macro pushTag(value: Node, context: ClassFieldDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.MemberExpr, line: value.line, column: value.column, object: { kind: NodeKind.MemberExpr, line: value.line, column: value.column, object: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "this" }, property: "tags" }, property: "push" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "tagged" } ] } });
	return value;
}

macro onStaticMethod(value: Node, context: ClassMethodDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "mark" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "sm-init" } ] } });
	return value;
}
macro onStaticA(value: Node, context: ClassFieldDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "mark" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "sa-extra" } ] } });
	return value;
}
macro onStaticB(value: Node, context: ClassFieldDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "mark" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "sb-extra" } ] } });
	return value;
}
macro onStaticClass(value: Node, context: ClassDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "mark" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "class-init" } ] } });
	return value;
}

macro keepClass(value: Node, context: ClassDecoratorContext): Node { return value; }

class P {
	constructor() { mark("P-ctor"); }
}

@keepClass
class K extends P {
	a: int32 = mark("init-a");
	@onMethod m(): void {}
	@onFieldB b: int32 = mark("init-b");
	@onFieldC c: int32 = mark("init-c");
	readonly d: int32 = mark("init-d");
	constructor() { super(); mark("K-body"); }
}

class N {
	@onMethod m2(): void {}
	constructor() { mark("N-body"); }
}

@onStaticClass
class S {
	@onStaticA static sa: int32 = mark("s-init-a");
	@onStaticMethod static sm(): void {}
	@onStaticB static sb: int32 = mark("s-init-b");
	static sc: int32 = mark("s-init-c");
}

class Tagged {
	@pushTag tags: string[] = [];
	run(): int32 { return this.tags.length; }
}

function expect(actual: string, want: string, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

const staticTrace: string = trace;

function main(): int32 {
	let rc: int32 = 0;
	rc += expect(staticTrace, "sm-init,s-init-a,sa-extra,s-init-b,sb-extra,s-init-c,class-init,", "staticOrder");
	rc += expect(`${S.sa + S.sb + S.sc}`, "3", "staticValuesKept");
	trace = "";
	const k = new K();
	rc += expect(trace, "P-ctor,m-init,init-a,init-b,fb-extra,init-c,fc-extra,init-d,K-body,", "instanceOrder");
	rc += expect(`${k.a + k.b + k.c + k.d}`, "4", "fieldValuesKept");
	trace = "";
	const n = new N();
	rc += expect(trace, "m-init,N-body,", "noFieldsOrder");
	const t = new Tagged();
	rc += expect(`${t.run()}`, "1", "fieldInitializerSeesItsOwnValue");
	if (rc == 0) { console.log("GUARD-OK decoratorInitializerOrder"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
