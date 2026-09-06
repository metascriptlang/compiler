// bug109 — assignment used as a VALUE reached codegen untyped
//
// Symptom:    `return l = "y" + l` printed garbage on C and the right answer
//             on JS; `a = b = "x"` silently dropped the inner store;
//             `(n = 5).toString()` printed "<object>" on BOTH backends;
//             `while ((l = f()) !== "")` failed the C compiler and produced
//             NaN under node; `const r: int32 = (s = "x")` passed the checker
//             and died in clang.
// Root cause: inferBinaryOp had no arm for the assignment operators, so the
//             BinaryExpr arm's only exit typed every assignment VALUE as the
//             checker's internal pending-inference sentinel. That sentinel
//             passes the leniency gates that exist to serve inference, so
//             nothing was type-checked and codegen received no type — the
//             same borrowed-identity failure as `any` in bug069.
// Fix:        assignment is a statement (Nim: nkAsgn is produced only by
//             parseExprStmt, `=` has no precedence entry). Assignment
//             operators now type as void, and an assignment outside
//             statement position is a checker error naming the split form.

import { hasError, strictErrorCount } from "../handoff/helpers";

test "bug109: assignment as a return value is rejected" {
	assert hasError("function f(x: string): string { let l = x; return l = x; }", "assignment is a statement");
}

test "bug109: chained assignment is rejected" {
	assert hasError("function f(): void { let a = \"\"; let b = \"\"; a = b = \"x\"; }", "assignment is a statement");
}

test "bug109: assignment inside a condition is rejected" {
	assert hasError("function f(): void { let l = \"\"; while ((l = \"a\") !== \"\") { } }", "assignment is a statement");
}

test "bug109: member access on an assignment result is rejected" {
	assert hasError("function f(): string { let n = 0; return (n = 5).toString(); }", "assignment is a statement");
}

test "bug109: an assignment initializer is rejected" {
	assert hasError("function f(): void { let s = \"\"; const r: int32 = (s = \"x\"); }", "assignment is a statement");
}

test "bug109: statement-position assignment stays legal" {
	assert strictErrorCount("class B { v: string = \"\"; } function f(): void { let x = \"a\"; x = \"b\"; x += \"c\"; const arr: string[] = [\"p\"]; arr[0] = \"z\"; const b = new B(); b.v = \"w\"; }") == 0;
}

test "bug109: for-update assignment stays legal" {
	assert strictErrorCount("function f(): int32 { let n = 0; for (let i = 0; i < 3; i = i + 1) { n = n + i; } for (let j = 0; j < 3; j += 1) { n = n + j; } return n; }") == 0;
}
