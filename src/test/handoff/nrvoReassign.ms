// Test: reassignment of struct variable to NRVO call result
// Bug: `ext = findFoo(...)` emits `(ext = ((void)(T5_)))` — void cast on temp
// Verify at AST level: after fullPipeline, reassignment RHS CallExpr
// should have nodeType matching the struct, not void.

import { fullPipeline, findFnDecl } from "./helpers";
import { compileToC } from "../helpers";
import { Node, NodeKind, FunctionDeclData, BlockStmtData, ExprStmtData, BinaryExprData, CallExprData, VariableDeclData, TypeKind } from "../../ast/node";

// Walk statements to find the assignment `p = makePair(2)`
function findAssignment(fn: Node): Node {
	if (fn == null) return null as unknown as Node;
	const fd = fn.data as FunctionDeclData;
	if (fd.fnBody == null) return null as unknown as Node;
	const bd = fd.fnBody.data as BlockStmtData;
	for (const stmt of bd.statements) {
		if (stmt.kind == NodeKind.ExprStmt) {
			const ed = stmt.data as ExprStmtData;
			if (ed.expr.kind == NodeKind.BinaryExpr) {
				const bin = ed.expr.data as BinaryExprData;
				if (bin.operator == "=") return ed.expr;
			}
		}
	}
	return null as unknown as Node;
}

test "E2E C: struct reassignment from NRVO call stores the temp, not a void cast" {
	const c = compileToC("struct Pair { a: number; b: string; }\nfunction makePair(x: number): Pair { return { a: x, b: \"s\" }; }\nfunction main(): void {\n  let p: Pair = makePair(1);\n  p = makePair(2);\n  console.log(p.b);\n}");
	assert c.ok;
	assert c.value.contains("(p_1_ = T");
	assert !c.value.contains("((void)(T");
}

test "struct reassignment RHS has struct nodeType not void" {
	const src = "struct Pair { a: number; b: string; }\nfunction makePair(x: number): Pair { return { a: x, b: \"s\" }; }\nfunction main(): void {\n  let p: Pair = makePair(1);\n  p = makePair(2);\n}";
	const prog = fullPipeline(src);
	const fn = findFnDecl(prog, "main");
	assert fn != null;
	const assign = findAssignment(fn);
	assert assign != null;
	const bin = assign.data as BinaryExprData;
	assert bin.right.kind == NodeKind.CallExpr;
	assert bin.right.nodeType != null;
	assert bin.right.nodeType.kind == TypeKind.Struct;
}
