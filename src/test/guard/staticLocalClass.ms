// GUARD-JS
// The statics of a class declared inside a function body keep their values on
// both backends: a computed initializer, a static block, and a decorated
// static field.
//
// A red guard means a static initializer was stripped from the class the
// function body actually reads.

import { Node, NodeKind, ClassFieldDecoratorContext } from "std/meta";

function seven(): int32 { return 7; }
function note(s: string): int32 { return 1; }

macro onField(value: Node, context: ClassFieldDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "note" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "extra" } ] } });
	return value;
}

function computed(): int32 {
	class L {
		static a: int32 = seven();
	}
	return L.a;
}

function blocked(): int32 {
	class B {
		static a: int32 = 0;
		static { B.a = 5; }
	}
	return B.a;
}

function decorated(): int32 {
	class M {
		@onField static f: int32 = seven();
	}
	return M.f;
}

function expect(actual: int32, want: int32, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

function main(): int32 {
	let rc: int32 = 0;
	rc += expect(computed() + computed(), 14, "computedStaticOfLocalClass");
	rc += expect(blocked(), 5, "staticBlockOfLocalClass");
	rc += expect(decorated(), 7, "decoratedStaticOfLocalClass");
	if (rc == 0) { console.log("GUARD-OK staticLocalClass"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
