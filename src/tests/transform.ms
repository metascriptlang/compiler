// Transform E2E Tests — integration tests for all AST transforms
// Uses shared helpers from testUtil.ms

import { NodeKind } from "../ast/node";
import { lowerDefer } from "../transform/lowering/deferLower";
import { lowerConstFold } from "../transform/coercion/constantFolding";
import { lowerStringConcatFlatten } from "../transform/coercion/stringConcatFlatten";
import { lowerOptionalChain } from "../transform/coercion/optionalChain";
import { lowerNullishCoalesce } from "../transform/coercion/nullishCoalesce";
import { lowerTypeCoercion } from "../transform/coercion/typeCoercion";
import { lowerStringTruthiness } from "../transform/coercion/stringTruthiness";
import { lowerDestructuring } from "../transform/desugar/destructuringLower";
import { lowerSpread } from "../transform/desugar/spreadExpand";
import { lowerForLoop } from "../transform/lowering/forLoopLower";
import { lowerForOf } from "../transform/lowering/forOfLower";
import { lowerResult } from "../transform/desugar/resultDesugar";
import { lowerResultFieldCheck } from "../transform/desugar/resultFieldCheck";
import { lowerMatch } from "../transform/lowering/matchLower";
import { lowerTailCall } from "../transform/lowering/tailCallLower";
import { markClosureCalls } from "../transform/c/closureCallMarker";
import { markPointerParams } from "../transform/c/pointerParam";
import { injectRangeChecks } from "../transform/c/rangeCheckInject";
import { coerceOptionals } from "../transform/c/optionalCoercion";
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

// ===== Constant Folding =====

testGroup("Constant Folding", () => {
	test("number addition", () => {
		check(firstExprKindAfter("2 + 3;", lowerConstFold) === NodeKind.NumberLiteral);
	});
	test("string concat", () => {
		check(firstExprKindAfter("\"a\" + \"b\";", lowerConstFold) === NodeKind.StringLiteral);
	});
	test("boolean negation", () => {
		check(firstExprKindAfter("!true;", lowerConstFold) === NodeKind.BooleanLiteral);
	});
	test("comparison", () => {
		check(firstExprKindAfter("5 > 3;", lowerConstFold) === NodeKind.BooleanLiteral);
	});
	test("non-constant unchanged", () => {
		check(firstExprKindAfter("x + y;", lowerConstFold) === NodeKind.BinaryExpr);
	});
	test("nested constant folds bottom-up", () => {
		check(firstExprKindAfter("(2 + 3) * 4;", lowerConstFold) === NodeKind.NumberLiteral);
	});
});

// ===== String Concat Flatten =====

testGroup("String Concat Flatten", () => {
	test("variable addition unchanged", () => {
		check(firstExprKindAfter("x + y;", lowerStringConcatFlatten) === NodeKind.BinaryExpr);
	});
	test("non-binary unchanged", () => {
		check(firstExprKindAfter("f();", lowerStringConcatFlatten) === NodeKind.CallExpr);
	});
	test("non-string binary unchanged", () => {
		check(firstExprKindAfter("x * y;", lowerStringConcatFlatten) === NodeKind.BinaryExpr);
	});
	test("passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerStringConcatFlatten) === 1);
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

// ===== String Truthiness =====

testGroup("String Truthiness", () => {
	test("comparison condition unchanged", () => {
		check(firstStmtKindAfter("if (x > 0) {}", lowerStringTruthiness) === NodeKind.IfStmt);
	});
	test("bool literal condition unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", lowerStringTruthiness) === NodeKind.WhileStmt);
	});
	test("call condition unchanged", () => {
		check(firstStmtKindAfter("if (f()) {}", lowerStringTruthiness) === NodeKind.IfStmt);
	});
	test("equality condition unchanged", () => {
		check(firstStmtKindAfter("if (x === y) {}", lowerStringTruthiness) === NodeKind.IfStmt);
	});
	test("non-condition passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerStringTruthiness) === 1);
	});
});

// ===== Destructuring Lowering =====

testGroup("Destructuring Lowering", () => {
	test("array 2 elements", () => {
		check(stmtCountAfter("const [a, b] = f();", lowerDestructuring) === 3);
	});
	test("first stmt is temp VarDecl", () => {
		check(firstStmtKindAfter("const [a, b] = f();", lowerDestructuring) === NodeKind.VariableDecl);
	});
	test("object destructuring", () => {
		check(stmtCountAfter("const { x, y } = f();", lowerDestructuring) === 3);
	});
	test("simple RHS skips temp", () => {
		check(stmtCountAfter("const [a, b] = myVar;", lowerDestructuring) === 2);
	});
	test("non-destructuring passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerDestructuring) === 1);
	});
});

// ===== Spread Expansion =====

testGroup("Spread Expansion", () => {
	test("no spread passthrough", () => {
		check(firstExprKindAfter("f(a, b);", lowerSpread) === NodeKind.CallExpr);
	});
	test("spread array literal inlined", () => {
		check(firstExprKindAfter("f(...[1, 2]);", lowerSpread) === NodeKind.CallExpr);
	});
	test("non-call unchanged", () => {
		check(firstExprKindAfter("x + y;", lowerSpread) === NodeKind.BinaryExpr);
	});
	test("nested call unchanged", () => {
		check(firstExprKindAfter("f(g());", lowerSpread) === NodeKind.CallExpr);
	});
	test("non-expr passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerSpread) === 1);
	});
});

// ===== For Loop Lowering =====

testGroup("For Loop Lowering", () => {
	test("basic for becomes block", () => {
		check(firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForLoop) === NodeKind.BlockStmt);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", lowerForLoop) === NodeKind.WhileStmt);
	});
	test("for-of unchanged", () => {
		check(firstStmtKindAfter("for (const x of arr) { x; }", lowerForLoop) === NodeKind.ForOfStmt);
	});
	test("non-loop passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerForLoop) === 1);
	});
	test("preserves surrounding stmts", () => {
		check(stmtCountAfter("let a = 1; for (let i = 0; i < 2; i++) {} let b = 2;", lowerForLoop) === 3);
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

// ===== Result Field Check =====

testGroup("Result Field Check", () => {
	test("non-member unchanged", () => {
		check(firstExprKindAfter("x + y;", lowerResultFieldCheck) === NodeKind.BinaryExpr);
	});
	test("regular member unchanged", () => {
		check(firstExprKindAfter("obj.name;", lowerResultFieldCheck) === NodeKind.MemberExpr);
	});
	test("non-result .value unchanged", () => {
		check(firstExprKindAfter("obj.value;", lowerResultFieldCheck) === NodeKind.MemberExpr);
	});
	test("call expr unchanged", () => {
		check(firstExprKindAfter("f();", lowerResultFieldCheck) === NodeKind.CallExpr);
	});
	test("passthrough for non-expr", () => {
		check(stmtCountAfter("const x = 1;", lowerResultFieldCheck) === 1);
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

// ===== Tail Call Lowering =====

testGroup("Tail Call Lowering", () => {
	test("non-recursive unchanged", () => {
		check(firstStmtKindAfter("function foo(x: number): number { return x + 1; }", lowerTailCall) === NodeKind.FunctionDecl);
	});
	test("simple passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerTailCall) === 1);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", lowerTailCall) === NodeKind.WhileStmt);
	});
	test("non-function passthrough", () => {
		check(stmtCountAfter("let a = 1; let b = 2;", lowerTailCall) === 2);
	});
});

// C-Backend tests are now inline in each transform file:
// - closureCallMarker.ms, pointerParam.ms, rangeCheckInject.ms, optionalCoercion.ms
// Imports above ensure those files are compiled when running this test file.
