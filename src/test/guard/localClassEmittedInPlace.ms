// GUARD-JS

import { Node, NodeKind, ClassFieldDecoratorContext } from "std/meta";

let inits: int32 = 0;
let trace: string = "";
function bump(): int32 { inits += 1; return inits; }
function mark(s: string): int32 { trace = trace + s + ","; return 1; }

macro onField(value: Node, context: ClassFieldDecoratorContext): Node {
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column, callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "mark" }, arguments: [ { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "extra" } ] } });
	return value;
}

function local(): int32 {
	class L {
		static a: int32 = bump();
	}
	return L.a;
}

function decorated(): int32 {
	class M {
		@onField static f: int32 = mark("init");
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
	rc += expect(local(), 1, "staticSeenByFirstCall");
	rc += expect(inits, 1, "staticInitializerRunsOncePerClassEvaluation");
	rc += expect(decorated(), 1, "decoratedStaticSeen");
	if (trace != "init,extra,") {
		console.log(`GUARD-FAIL decoratorInitializerFollowsField: got ${trace}, want init,extra,`);
		rc += 1;
	}
	if (rc == 0) { console.log("GUARD-OK localClassEmittedInPlace"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
