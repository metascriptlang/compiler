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

import { Node, NodeKind, ProgramData, IdentifierData, BinaryExprData, UnaryExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, SpreadExprData, NewExprData, UpdateExprData, TypeAssertionData, VariableDeclData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, BlockStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ThrowStmtData, DoWhileStmtData, ExportDeclData, MoveExprData, HiddenDerefData, HiddenStdConvData, Symbol, isEmptyBlock, SymbolKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { makeSymbol } from "../checker/symbol";
import { noneType } from "../checker/types";
import { OuterEntry } from "./scope";
import { parseInput } from "../transform/testUtil";

// ===== nodeReferencesVar — recursive check =====
// Returns true if `node` (or any sub-expression) references `varName`.

function anyChildReferences(nodes: Node[], targetSym: Symbol): boolean {
	for (const n of nodes) {
		if (nodeReferencesVar(n, targetSym)) return true;
	}
	return false;
}

export function nodeReferencesVar(node: Node, targetSym: Symbol): boolean {
	if (node === null || targetSym === null) return false;

	return match (node.kind) {
		// Expression nodes
		NodeKind.Identifier => node.resolvedSym === targetSym,
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			return nodeReferencesVar(d.left, targetSym) || nodeReferencesVar(d.right, targetSym);
		},
		NodeKind.UnaryExpr => nodeReferencesVar((node.data as UnaryExprData).operand, targetSym),
		NodeKind.UpdateExpr => nodeReferencesVar((node.data as UpdateExprData).updateArg, targetSym),
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			return nodeReferencesVar(d.callee, targetSym) || anyChildReferences(d.arguments, targetSym);
		},
		NodeKind.MemberExpr => nodeReferencesVar((node.data as MemberExprData).object, targetSym),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			return nodeReferencesVar(d.array, targetSym) || nodeReferencesVar(d.index, targetSym);
		},
		NodeKind.ObjectLiteral => anyChildReferences((node.data as ObjectLiteralData).properties, targetSym),
		NodeKind.ArrayLiteral => anyChildReferences((node.data as ArrayLiteralData).elements, targetSym),
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			return nodeReferencesVar(d.ternaryCondition, targetSym)
				|| nodeReferencesVar(d.ternaryConsequent, targetSym)
				|| nodeReferencesVar(d.ternaryAlternate, targetSym);
		},
		NodeKind.SpreadExpr => nodeReferencesVar((node.data as SpreadExprData).spreadArg, targetSym),
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			return nodeReferencesVar(d.newCallee, targetSym) || anyChildReferences(d.newArguments, targetSym);
		},
		NodeKind.TypeAssertion => nodeReferencesVar((node.data as TypeAssertionData).asExpr, targetSym),
		NodeKind.MoveExpr => nodeReferencesVar((node.data as MoveExprData).moveArg, targetSym),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => nodeReferencesVar((node.data as HiddenDerefData).expr, targetSym),
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => nodeReferencesVar((node.data as HiddenStdConvData).convExpr, targetSym),

		// Statement nodes
		NodeKind.ExprStmt => nodeReferencesVar((node.data as ExprStmtData).expr, targetSym),
		NodeKind.VariableDecl => nodeReferencesVar((node.data as VariableDeclData).initializer, targetSym),
		NodeKind.ReturnStmt => nodeReferencesVar((node.data as ReturnStmtData).argument, targetSym),
		NodeKind.ThrowStmt => nodeReferencesVar((node.data as ThrowStmtData).throwArg, targetSym),
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return nodeReferencesVar(d.condition, targetSym)
				|| nodeReferencesVar(d.consequent, targetSym)
				|| nodeReferencesVar(d.alternate, targetSym);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			return nodeReferencesVar(d.whileCondition, targetSym) || nodeReferencesVar(d.whileBody, targetSym);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			return nodeReferencesVar(d.forInit, targetSym) || nodeReferencesVar(d.forCondition, targetSym)
				|| nodeReferencesVar(d.forUpdate, targetSym) || nodeReferencesVar(d.forBody, targetSym);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			return nodeReferencesVar(d.forOfIterable, targetSym) || nodeReferencesVar(d.forOfBody, targetSym);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			return nodeReferencesVar(d.doBody, targetSym) || nodeReferencesVar(d.doCondition, targetSym);
		},
		NodeKind.BlockStmt => anyChildReferences((node.data as BlockStmtData).statements, targetSym),
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			return nodeReferencesVar(d.tryBody, targetSym)
				|| nodeReferencesVar(d.catchBody, targetSym)
				|| nodeReferencesVar(d.finallyBody, targetSym);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			return nodeReferencesVar(d.switchDisc, targetSym) || anyChildReferences(d.switchCases, targetSym);
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			return anyChildReferences(d.caseTests, targetSym) || anyChildReferences(d.caseStmts, targetSym);
		},
		NodeKind.ExportDecl => nodeReferencesVar((node.data as ExportDeclData).exportedDecl, targetSym),

		// Function boundaries: don't look inside inner functions
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => false,
		_ => false,
	};
}

// ===== isLastReadInBlock — forward scan =====
// Returns true if `varName` at `stmtIndex` is not referenced in stmts[stmtIndex+1..].

export function isLastReadInBlock(targetSym: Symbol, stmtIndex: number, stmts: Node[]): boolean {
	for (let i = stmtIndex + 1; i < stmts.length; i += 1) {
		if (nodeReferencesVar(stmts[i], targetSym)) return false;
	}
	return true;
}

// ===== Termination Analysis (lightweight CFG) =====
// Determines if control flow from a given point will DEFINITELY terminate
// (via return/break/throw/continue) before reaching the end of the block.
// When a block definitely terminates, outer scope references are unreachable
// from this code path — enabling move optimizations inside terminated branches.
//
// This replaces a full CFG builder with a focused analysis that captures the
// most common optimization: guard clause patterns (if (err) return; use(x);)
// and exhaustive if/else where both branches terminate.

function isTerminatingStmt(node: Node): boolean {
	if (node === null) return false;
	const k = node.kind;
	return k === NodeKind.ReturnStmt
		|| k === NodeKind.ThrowStmt
		|| k === NodeKind.BreakStmt
		|| k === NodeKind.ContinueStmt;
}

// Returns true if block contents definitely terminate (never fall through).
function blockDefinitelyTerminates(node: Node): boolean {
	if (node === null) return false;
	if (node.kind !== NodeKind.BlockStmt) return isTerminatingStmt(node);
	const stmts = (node.data as BlockStmtData).statements;
	return stmtsDefinitelyTerminate(stmts, 0);
}

// Returns true if stmts[fromIndex..] definitely terminate before reaching end.
function stmtsDefinitelyTerminate(stmts: Node[], fromIndex: number): boolean {
	let i = fromIndex;
	while (i < stmts.length) {
		const stmt = stmts[i];
		if (stmt === null) {
			i = i + 1;
			continue;
		}
		// Direct terminating statement
		if (isTerminatingStmt(stmt)) return true;
		// If-else: terminates if BOTH branches terminate
		if (stmt.kind === NodeKind.IfStmt) {
			const d = stmt.data as IfStmtData;
			if (d.alternate !== null && !isEmptyBlock(d.alternate)) {
				if (blockDefinitelyTerminates(d.consequent)
					&& blockDefinitelyTerminates(d.alternate)) {
					return true;
				}
			}
		}
		i = i + 1;
	}
	return false;
}


// ===== isLastReadInContext — cross-scope forward scan with termination analysis =====
// Like isLastReadInBlock, but also checks remaining statements in outer scopes.
// Stops at function boundaries (variables don't escape function scope).
//
// CFG enhancement: if the remaining statements in the current block definitely
// terminate (return/break/throw/continue), outer scope references are unreachable
// from this path — skip the outer scope check and return true.

export function isLastReadInContext(targetSym: Symbol, stmtIndex: number, stmts: Node[], outerCtx: OuterEntry[]): boolean {
	// Check remaining stmts in current block
	for (let i = stmtIndex + 1; i < stmts.length; i += 1) {
		if (nodeReferencesVar(stmts[i], targetSym)) return false;
	}
	// CFG enhancement: if remaining stmts definitely terminate, outer scope
	// is unreachable from this path — variable IS last-read regardless of outer uses.
	if (stmtsDefinitelyTerminate(stmts, stmtIndex + 1)) return true;
	// Check outer scopes (innermost first)
	let oi = outerCtx.length;
	while (oi > 0) {
		oi -= 1;
		const entry = outerCtx[oi];
		if (entry.isFunctionBoundary) break;  // don't look past function boundaries
		// CFG enhancement: if outer scope's remaining stmts terminate,
		// skip further outer scope checks (that scope never falls through either)
		if (stmtsDefinitelyTerminate(entry.outerStmts, entry.fromIndex)) {
			// Still check this scope's remaining stmts for references
			let j = entry.fromIndex;
			while (j < entry.outerStmts.length) {
				if (nodeReferencesVar(entry.outerStmts[j], targetSym)) return false;
				j = j + 1;
			}
			return true;  // this scope terminates, no need to check further outer
		}
		for (let j = entry.fromIndex; j < entry.outerStmts.length; j += 1) {
			if (nodeReferencesVar(entry.outerStmts[j], targetSym)) return false;
		}
	}
	return true;
}

// ===== deepAliases — MOVED to alias.ms =====
// Path-level alias analysis now lives in src/analyzer/alias.ms.
// nodeReferencesVar is still used by isLastReadInBlock/isLastReadInContext.

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

// ===== Test Helpers: Symbol Attachment =====

function makeTestSym(name: string): Symbol {
	return makeSymbol(name, SymbolKind.Variable, noneType(), false);
}

function attachSymToNode(node: Node, name: string, sym: Symbol): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		if ((node.data as IdentifierData).name === name) node.resolvedSym = sym;
		return;
	}
	// Scope boundary: don't recurse into nested function bodies.
	if (node.kind === NodeKind.FunctionDecl
		|| node.kind === NodeKind.ArrowFunction
		|| node.kind === NodeKind.FunctionExpr) return;
	forEachChild(node, (c: Node): void => { attachSymToNode(c, name, sym); });
}

function attachSym(nodes: Node[], name: string, sym: Symbol): void {
	for (const n of nodes) { attachSymToNode(n, name, sym); }
}

// ===== Tests =====
test "identifier matches" {
	const expr = getExpr("x;");
	const symX = makeTestSym("x");
	attachSymToNode(expr, "x", symX);
	assert nodeReferencesVar(expr, symX);
	assert !nodeReferencesVar(expr, makeTestSym("y"));
}

test "binary expr references" {
	const expr = getExpr("x + y;");
	const symX = makeTestSym("x");
	const symY = makeTestSym("y");
	attachSymToNode(expr, "x", symX);
	attachSymToNode(expr, "y", symY);
	assert nodeReferencesVar(expr, symX);
	assert nodeReferencesVar(expr, symY);
	assert !nodeReferencesVar(expr, makeTestSym("z"));
}

test "call expr references" {
	const expr = getExpr("foo(a, b);");
	const symFoo = makeTestSym("foo");
	const symA = makeTestSym("a");
	const symB = makeTestSym("b");
	attachSymToNode(expr, "foo", symFoo);
	attachSymToNode(expr, "a", symA);
	attachSymToNode(expr, "b", symB);
	assert nodeReferencesVar(expr, symFoo);
	assert nodeReferencesVar(expr, symA);
	assert nodeReferencesVar(expr, symB);
	assert !nodeReferencesVar(expr, makeTestSym("c"));
}

test "member expr references object" {
	const expr = getExpr("obj.prop;");
	const symObj = makeTestSym("obj");
	attachSymToNode(expr, "obj", symObj);
	assert nodeReferencesVar(expr, symObj);
	assert !nodeReferencesVar(expr, makeTestSym("prop"));
}

test "function boundary stops scan" {
	const stmts = getStmts("function f() { return x; }");
	const symX = makeTestSym("x");
	attachSym(stmts, "x", symX);
	assert stmts.length > 0;
	assert !nodeReferencesVar(stmts[0], symX);
}

test "null node" { assert !nodeReferencesVar(null as unknown as Node, makeTestSym("x")); }

test "last stmt is last read" {
	const stmts = getStmts("const a = 1; const b = a;");
	const symA = makeTestSym("a");
	attachSym(stmts, "a", symA);
	assert isLastReadInBlock(symA, 1, stmts);
}

test "not last when used later" {
	const stmts = getStmts("const a = 1; const b = a; const c = a;");
	const symA = makeTestSym("a");
	attachSym(stmts, "a", symA);
	assert !isLastReadInBlock(symA, 1, stmts);
}

test "different var is last read" {
	const stmts = getStmts("const a = 1; const b = a; const c = b;");
	const symA = makeTestSym("a");
	attachSym(stmts, "a", symA);
	assert isLastReadInBlock(symA, 1, stmts);
}

test "no outer context = same as isLastReadInBlock" {
	const stmts = getStmts("const a = 1; const b = a;");
	const symA = makeTestSym("a");
	attachSym(stmts, "a", symA);
	const emptyOuter: OuterEntry[] = [];
	assert isLastReadInContext(symA, 1, stmts, emptyOuter);
}

test "not last when used in outer scope" {
	const outerStmts = getStmts("const a = 1; const c = a;");
	const innerStmts = getStmts("const b = a;");
	const symA = makeTestSym("a");
	attachSym(outerStmts, "a", symA);
	attachSym(innerStmts, "a", symA);
	const outer: OuterEntry[] = [
		{ outerStmts, fromIndex: 1, isFunctionBoundary: false },
	];
	assert !isLastReadInContext(symA, 0, innerStmts, outer);
}

test "function boundary stops outer search" {
	const outerStmts = getStmts("const a = 1; const c = a;");
	const innerStmts = getStmts("const b = a;");
	const symA = makeTestSym("a");
	attachSym(outerStmts, "a", symA);
	attachSym(innerStmts, "a", symA);
	const outer: OuterEntry[] = [
		{ outerStmts, fromIndex: 1, isFunctionBoundary: false },
		{ outerStmts: [], fromIndex: 0, isFunctionBoundary: true },
	];
	assert isLastReadInContext(symA, 0, innerStmts, outer);
}

test "return terminates block" {
	const innerStmts = getStmts("const b = a; return b;");
	const outerStmts = getStmts("foo(a);");
	const symA = makeTestSym("a");
	attachSym(innerStmts, "a", symA);
	attachSym(outerStmts, "a", symA);
	const outer: OuterEntry[] = [
		{ outerStmts, fromIndex: 0, isFunctionBoundary: false },
	];
	assert isLastReadInContext(symA, 0, innerStmts, outer);
}

test "throw terminates block" {
	const innerStmts = getStmts("const b = a; throw b;");
	const outerStmts = getStmts("foo(a);");
	const symA = makeTestSym("a");
	attachSym(innerStmts, "a", symA);
	attachSym(outerStmts, "a", symA);
	const outer: OuterEntry[] = [
		{ outerStmts, fromIndex: 0, isFunctionBoundary: false },
	];
	assert isLastReadInContext(symA, 0, innerStmts, outer);
}

test "no termination checks outer normally" {
	const innerStmts = getStmts("const b = a;");
	const outerStmts = getStmts("foo(a);");
	const symA = makeTestSym("a");
	attachSym(innerStmts, "a", symA);
	attachSym(outerStmts, "a", symA);
	const outer: OuterEntry[] = [
		{ outerStmts, fromIndex: 0, isFunctionBoundary: false },
	];
	assert !isLastReadInContext(symA, 0, innerStmts, outer);
}

test "exhaustive if-else terminates" {
	const innerStmts = getStmts("const b = a; if (c) { return x; } else { return y; }");
	const outerStmts = getStmts("foo(a);");
	const symA = makeTestSym("a");
	attachSym(innerStmts, "a", symA);
	attachSym(outerStmts, "a", symA);
	const outer: OuterEntry[] = [
		{ outerStmts, fromIndex: 0, isFunctionBoundary: false },
	];
	assert isLastReadInContext(symA, 0, innerStmts, outer);
}

test "non-exhaustive if does not terminate" {
	const innerStmts = getStmts("const b = a; if (c) { return x; }");
	const outerStmts = getStmts("foo(a);");
	const symA = makeTestSym("a");
	attachSym(innerStmts, "a", symA);
	attachSym(outerStmts, "a", symA);
	const outer: OuterEntry[] = [
		{ outerStmts, fromIndex: 0, isFunctionBoundary: false },
	];
	assert !isLastReadInContext(symA, 0, innerStmts, outer);
}
