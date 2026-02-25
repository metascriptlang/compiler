// Transform E2E Tests — integration tests for all AST transforms
// Uses shared helpers from testUtil.ms

import { NodeKind } from "../ast/node";
import { lowerDefer } from "../transform/lowering/deferLower";
import { lowerOptionalChain } from "../transform/lowering/optionalChain";
import { lowerNullishCoalesce } from "../transform/lowering/nullishCoalesce";
import { lowerTypeCoercion } from "../transform/lowering/typeCoercion";
import { lowerForOf } from "../transform/lowering/forOfLower";
import { lowerResult } from "../transform/lowering/resultDesugar";
import { lowerMatch } from "../transform/lowering/matchLower";
import { test, check, testGroup } from "std/testing";
import {
	stmtCountAfter, firstStmtKindAfter, firstExprKindAfter,
} from "../transform/testUtil";

// ===== Defer Lowering =====

testGroup("Defer Lowering", () => {
	test("no defer passthrough", () => {
		check(firstStmtKindAfter("const x = 1;", lowerDefer) === NodeKind.VariableDecl);
	});
	test("single defer becomes try-catch", () => {
		check(firstStmtKindAfter("defer cleanup(); work();", lowerDefer) === NodeKind.TryCatchStmt);
	});
	test("defer at start", () => {
		check(stmtCountAfter("defer cleanup();", lowerDefer) === 1);
		check(firstStmtKindAfter("defer cleanup();", lowerDefer) === NodeKind.TryCatchStmt);
	});
	test("defer preserves before stmts", () => {
		check(stmtCountAfter("setup(); defer cleanup(); work();", lowerDefer) === 2);
	});
	test("multiple defers nest", () => {
		check(stmtCountAfter("defer a(); defer b(); work();", lowerDefer) === 1);
		check(firstStmtKindAfter("defer a(); defer b(); work();", lowerDefer) === NodeKind.TryCatchStmt);
	});
});

// ===== Optional Chain Lowering =====

testGroup("Optional Chain Lowering", () => {
	test("regular member unchanged", () => {
		check(firstExprKindAfter("a.b;", lowerOptionalChain) === NodeKind.MemberExpr);
	});
	test("optional chain becomes conditional", () => {
		check(firstExprKindAfter("a?.b;", lowerOptionalChain) === NodeKind.ConditionalExpr);
	});
	test("call expr unchanged", () => {
		check(firstExprKindAfter("f();", lowerOptionalChain) === NodeKind.CallExpr);
	});
});

// ===== Nullish Coalesce Lowering =====

testGroup("Nullish Coalesce Lowering", () => {
	test("nullish coalesce becomes conditional", () => {
		check(firstExprKindAfter("x ?? 42;", lowerNullishCoalesce) === NodeKind.ConditionalExpr);
	});
	test("other binary unchanged", () => {
		check(firstExprKindAfter("x + y;", lowerNullishCoalesce) === NodeKind.BinaryExpr);
	});
	test("logical or unchanged", () => {
		check(firstExprKindAfter("x || y;", lowerNullishCoalesce) === NodeKind.BinaryExpr);
	});
});

// ===== Type Coercion Lowering =====

testGroup("Type Coercion Lowering", () => {
	test("String(x) becomes call", () => {
		check(firstExprKindAfter("String(x);", lowerTypeCoercion) === NodeKind.CallExpr);
	});
	test("Number(x) unchanged", () => {
		check(firstExprKindAfter("Number(x);", lowerTypeCoercion) === NodeKind.CallExpr);
	});
	test("regular call unchanged", () => {
		check(firstExprKindAfter("foo(x);", lowerTypeCoercion) === NodeKind.CallExpr);
	});
	test("String() no args unchanged", () => {
		check(firstExprKindAfter("String();", lowerTypeCoercion) === NodeKind.CallExpr);
	});
});

// ===== ForOf Lowering =====

testGroup("ForOf Lowering", () => {
	test("for-of becomes block", () => {
		check(firstStmtKindAfter("for (const x of arr) { use(x); }", lowerForOf) === NodeKind.BlockStmt);
	});
	test("regular for unchanged", () => {
		check(firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForOf) === NodeKind.ForStmt);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", lowerForOf) === NodeKind.WhileStmt);
	});
	test("for-of preserves surrounding stmts", () => {
		check(stmtCountAfter("x(); for (const i of arr) {} y();", lowerForOf) === 3);
	});
});

// ===== Result Desugar =====

testGroup("Result Desugar", () => {
	test("var decl try expands to 3 stmts", () => {
		check(stmtCountAfter("const x = try f;", lowerResult) === 3);
	});
	test("var decl try first is VariableDecl", () => {
		check(firstStmtKindAfter("const x = try f;", lowerResult) === NodeKind.VariableDecl);
	});
	test("try catch expands to 2 stmts", () => {
		check(stmtCountAfter("const x = try f catch \"default\";", lowerResult) === 2);
	});
	test("no try passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerResult) === 1);
	});
	test("multiple stmts preserved", () => {
		check(stmtCountAfter("let a = 1; const x = try f; let b = 2;", lowerResult) === 5);
	});
});

// ===== Match Lowering =====

testGroup("Match Lowering", () => {
	test("match stmt becomes if chain", () => {
		check(stmtCountAfter("match (x) { 1 => foo(), _ => bar() }", lowerMatch) === 2);
	});
	test("match first stmt is VarDecl (discriminant temp)", () => {
		check(firstStmtKindAfter("match (x) { 1 => a(), _ => b() }", lowerMatch) === NodeKind.VariableDecl);
	});
	test("no match passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerMatch) === 1);
	});
	test("match preserves surrounding stmts", () => {
		check(stmtCountAfter("let a = 1; match (x) { _ => b() } let c = 2;", lowerMatch) === 4);
	});
});
