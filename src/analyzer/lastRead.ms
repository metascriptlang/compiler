// Last-Read Analysis — scope-local forward scan for move optimization
//
// Determines if a given use of variable `x` is the last read in the current
// statement list. When a use is last-read, we can MOVE instead of COPY.
//
// Also provides deepAliases: checks if an expression references a variable
// anywhere in its subtree (for self-assignment safety).
//
// Phase 1: Conservative scope-local forward scan.
// Phase 2 (future): CFG-based analysis for cross-block accuracy.

import {
	Node, NodeKind, ProgramData,
	IdentifierData, BinaryExprData, UnaryExprData, CallExprData,
	MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData,
	ConditionalExprData, SpreadExprData, NewExprData,
	UpdateExprData, TypeAssertionData,
	VariableDeclData, ExprStmtData, ReturnStmtData, IfStmtData,
	WhileStmtData, ForStmtData, ForOfStmtData, BlockStmtData,
	TryCatchStmtData, SwitchStmtData, SwitchCaseData,
	ThrowStmtData, DoWhileStmtData, FunctionDeclData,
	ExportDeclData, MoveExprData,
} from "../ast/node";
import { test, check, testGroup } from "std/testing";
import { parseInput } from "../transform/testUtil";

// ===== nodeReferencesVar — recursive check =====
// Returns true if `node` (or any sub-expression) references `varName`.

export function nodeReferencesVar(node: Node, varName: string): boolean {
	if (node === null) return false;

	return match (node.kind) {
		// Expression nodes
		NodeKind.Identifier => (node.data as IdentifierData).name === varName,
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			nodeReferencesVar(d.left, varName) || nodeReferencesVar(d.right, varName)
		},
		NodeKind.UnaryExpr => nodeReferencesVar((node.data as UnaryExprData).operand, varName),
		NodeKind.UpdateExpr => nodeReferencesVar((node.data as UpdateExprData).updateArg, varName),
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			if (nodeReferencesVar(d.callee, varName)) return true;
			for (const arg of d.arguments) {
				if (nodeReferencesVar(arg, varName)) return true;
			}
			false
		},
		NodeKind.MemberExpr => nodeReferencesVar((node.data as MemberExprData).object, varName),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			nodeReferencesVar(d.array, varName) || nodeReferencesVar(d.index, varName)
		},
		NodeKind.ObjectLiteral => {
			for (const prop of (node.data as ObjectLiteralData).properties) {
				if (nodeReferencesVar(prop, varName)) return true;
			}
			false
		},
		NodeKind.ArrayLiteral => {
			for (const elem of (node.data as ArrayLiteralData).elements) {
				if (nodeReferencesVar(elem, varName)) return true;
			}
			false
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			nodeReferencesVar(d.ternaryCondition, varName)
				|| nodeReferencesVar(d.ternaryConsequent, varName)
				|| nodeReferencesVar(d.ternaryAlternate, varName)
		},
		NodeKind.SpreadExpr => nodeReferencesVar((node.data as SpreadExprData).spreadArg, varName),
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			if (nodeReferencesVar(d.newCallee, varName)) return true;
			for (const arg of d.newArguments) {
				if (nodeReferencesVar(arg, varName)) return true;
			}
			false
		},
		NodeKind.TypeAssertion => nodeReferencesVar((node.data as TypeAssertionData).asExpr, varName),
		NodeKind.MoveExpr => nodeReferencesVar((node.data as MoveExprData).moveArg, varName),

		// Statement nodes
		NodeKind.ExprStmt => nodeReferencesVar((node.data as ExprStmtData).expr, varName),
		NodeKind.VariableDecl => nodeReferencesVar((node.data as VariableDeclData).initializer, varName),
		NodeKind.ReturnStmt => nodeReferencesVar((node.data as ReturnStmtData).argument, varName),
		NodeKind.ThrowStmt => nodeReferencesVar((node.data as ThrowStmtData).throwArg, varName),
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			nodeReferencesVar(d.condition, varName)
				|| nodeReferencesVar(d.consequent, varName)
				|| nodeReferencesVar(d.alternate, varName)
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			nodeReferencesVar(d.whileCondition, varName) || nodeReferencesVar(d.whileBody, varName)
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			nodeReferencesVar(d.forInit, varName) || nodeReferencesVar(d.forCondition, varName)
				|| nodeReferencesVar(d.forUpdate, varName) || nodeReferencesVar(d.forBody, varName)
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			nodeReferencesVar(d.forOfIterable, varName) || nodeReferencesVar(d.forOfBody, varName)
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			nodeReferencesVar(d.doBody, varName) || nodeReferencesVar(d.doCondition, varName)
		},
		NodeKind.BlockStmt => {
			for (const stmt of (node.data as BlockStmtData).statements) {
				if (nodeReferencesVar(stmt, varName)) return true;
			}
			false
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			nodeReferencesVar(d.tryBody, varName)
				|| nodeReferencesVar(d.catchBody, varName)
				|| nodeReferencesVar(d.finallyBody, varName)
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			if (nodeReferencesVar(d.switchDisc, varName)) return true;
			for (const c of d.switchCases) {
				if (nodeReferencesVar(c, varName)) return true;
			}
			false
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const t of d.caseTests) {
				if (nodeReferencesVar(t, varName)) return true;
			}
			for (const s of d.caseStmts) {
				if (nodeReferencesVar(s, varName)) return true;
			}
			false
		},
		NodeKind.ExportDecl => nodeReferencesVar((node.data as ExportDeclData).exportedDecl, varName),

		// Function boundaries: don't look inside inner functions
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => false,
		_ => false,
	};
}

// ===== isLastReadInBlock — forward scan =====
// Returns true if `varName` at `stmtIndex` is not referenced in stmts[stmtIndex+1..].

export function isLastReadInBlock(varName: string, stmtIndex: number, stmts: Node[]): boolean {
	let i = stmtIndex + 1;
	while (i < stmts.length) {
		if (nodeReferencesVar(stmts[i], varName)) return false;
		i += 1;
	}
	return true;
}

// ===== deepAliases — self-assignment detection =====
// Returns true if `expr` references `varName` anywhere in its tree.
// Used for: `x = f(x)` → must save old x before destroy.

export function deepAliases(varName: string, expr: Node): boolean {
	return nodeReferencesVar(expr, varName);
}

// ===== Test Helpers =====

function getStmts(input: string): Node[] {
	const result = parseInput(input);
	if (!result.ok) return [];
	const prog = result.value;
	const d = prog.data as ProgramData;
	return d.programStmts;
}

function getExpr(input: string): Node {
	const stmts = getStmts(input);
	if (stmts.length === 0) return null as unknown as Node;
	const stmt = stmts[0];
	if (stmt.kind !== NodeKind.ExprStmt) return null as unknown as Node;
	const d = stmt.data as ExprStmtData;
	return d.expr;
}

// ===== Tests =====

testGroup("nodeReferencesVar", () => {
	test("identifier matches", () => {
		const expr = getExpr("x;");
		check(nodeReferencesVar(expr, "x"));
		check(!nodeReferencesVar(expr, "y"));
	});
	test("binary expr references", () => {
		const expr = getExpr("x + y;");
		check(nodeReferencesVar(expr, "x"));
		check(nodeReferencesVar(expr, "y"));
		check(!nodeReferencesVar(expr, "z"));
	});
	test("call expr references", () => {
		const expr = getExpr("foo(a, b);");
		check(nodeReferencesVar(expr, "foo"));
		check(nodeReferencesVar(expr, "a"));
		check(nodeReferencesVar(expr, "b"));
		check(!nodeReferencesVar(expr, "c"));
	});
	test("member expr references object", () => {
		const expr = getExpr("obj.prop;");
		check(nodeReferencesVar(expr, "obj"));
		check(!nodeReferencesVar(expr, "prop"));
	});
	test("function boundary stops scan", () => {
		const stmts = getStmts("function f() { return x; }");
		check(stmts.length > 0);
		check(!nodeReferencesVar(stmts[0], "x"));
	});
	test("null node", () => {
		check(!nodeReferencesVar(null as unknown as Node, "x"));
	});
});

testGroup("isLastReadInBlock", () => {
	test("last stmt is last read", () => {
		const stmts = getStmts("const a = 1; const b = a;");
		check(isLastReadInBlock("a", 1, stmts));
	});
	test("not last when used later", () => {
		const stmts = getStmts("const a = 1; const b = a; const c = a;");
		check(!isLastReadInBlock("a", 1, stmts));
	});
	test("different var is last read", () => {
		const stmts = getStmts("const a = 1; const b = a; const c = b;");
		check(isLastReadInBlock("a", 1, stmts));
	});
});

testGroup("deepAliases", () => {
	test("simple alias", () => {
		const expr = getExpr("f(x);");
		check(deepAliases("x", expr));
		check(!deepAliases("y", expr));
	});
	test("nested alias", () => {
		const expr = getExpr("g(f(x));");
		check(deepAliases("x", expr));
	});
});
