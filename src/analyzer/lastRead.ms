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
import { OuterStack } from "./scope";
import { test, check, testGroup } from "std/testing";
import { parseInput } from "../transform/testUtil";

// ===== nodeReferencesVar — recursive check =====
// Returns true if `node` (or any sub-expression) references `varName`.

function anyChildReferences(nodes: Node[], varName: string): boolean {
	for (const n of nodes) {
		if (nodeReferencesVar(n, varName)) return true;
	}
	return false;
}

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
			nodeReferencesVar(d.callee, varName) || anyChildReferences(d.arguments, varName)
		},
		NodeKind.MemberExpr => nodeReferencesVar((node.data as MemberExprData).object, varName),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			nodeReferencesVar(d.array, varName) || nodeReferencesVar(d.index, varName)
		},
		NodeKind.ObjectLiteral => anyChildReferences((node.data as ObjectLiteralData).properties, varName),
		NodeKind.ArrayLiteral => anyChildReferences((node.data as ArrayLiteralData).elements, varName),
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			nodeReferencesVar(d.ternaryCondition, varName)
				|| nodeReferencesVar(d.ternaryConsequent, varName)
				|| nodeReferencesVar(d.ternaryAlternate, varName)
		},
		NodeKind.SpreadExpr => nodeReferencesVar((node.data as SpreadExprData).spreadArg, varName),
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			nodeReferencesVar(d.newCallee, varName) || anyChildReferences(d.newArguments, varName)
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
		NodeKind.BlockStmt => anyChildReferences((node.data as BlockStmtData).statements, varName),
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			nodeReferencesVar(d.tryBody, varName)
				|| nodeReferencesVar(d.catchBody, varName)
				|| nodeReferencesVar(d.finallyBody, varName)
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			nodeReferencesVar(d.switchDisc, varName) || anyChildReferences(d.switchCases, varName)
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			anyChildReferences(d.caseTests, varName) || anyChildReferences(d.caseStmts, varName)
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

// ===== isLastReadInContext — cross-scope forward scan =====
// Like isLastReadInBlock, but also checks remaining statements in outer scopes.
// Stops at function boundaries (variables don't escape function scope).

export function isLastReadInContext(varName: string, stmtIndex: number, stmts: Node[], outerCtx: OuterStack): boolean {
	// Check remaining stmts in current block
	let i = stmtIndex + 1;
	while (i < stmts.length) {
		if (nodeReferencesVar(stmts[i], varName)) return false;
		i += 1;
	}
	// Check outer scopes (innermost first)
	let oi = outerCtx.items.length;
	while (oi > 0) {
		oi -= 1;
		const entry = outerCtx.items[oi];
		if (entry.isFunctionBoundary) break;  // don't look past function boundaries
		let j = entry.fromIndex;
		while (j < entry.outerStmts.length) {
			if (nodeReferencesVar(entry.outerStmts[j], varName)) return false;
			j += 1;
		}
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

testGroup("isLastReadInContext", () => {
	test("no outer context = same as isLastReadInBlock", () => {
		const stmts = getStmts("const a = 1; const b = a;");
		const emptyOuter: OuterStack = { items: [] };
		check(isLastReadInContext("a", 1, stmts, emptyOuter));
	});
	test("not last when used in outer scope", () => {
		// Inner block: [const b = a]  Outer remaining: [const c = a]
		const outerStmts = getStmts("const a = 1; const c = a;");
		const innerStmts = getStmts("const b = a;");
		const outer: OuterStack = { items: [
			{ outerStmts, fromIndex: 1, isFunctionBoundary: false },
		] };
		// "a" at index 0 in innerStmts — not referenced in innerStmts[1..] (none)
		// But referenced in outerStmts[1] — so NOT last read
		check(!isLastReadInContext("a", 0, innerStmts, outer));
	});
	test("function boundary stops outer search", () => {
		const outerStmts = getStmts("const a = 1; const c = a;");
		const innerStmts = getStmts("const b = a;");
		const outer: OuterStack = { items: [
			{ outerStmts, fromIndex: 1, isFunctionBoundary: false },
			{ outerStmts: [], fromIndex: 0, isFunctionBoundary: true },
		] };
		// Function boundary blocks outer search — IS last read
		check(isLastReadInContext("a", 0, innerStmts, outer));
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
