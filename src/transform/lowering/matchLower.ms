// Match Lowering — transforms MatchStmt/MatchExpr → if-else chain or SwitchStmt
//
// MatchStmt: match (disc) { patterns => body, ... }
//   → const $match_0 = disc; if ($match_0 === p1) { body1 } else if ...
//
// MatchExpr in VariableDecl: const x = match (d) { p => e, ... }
//   → const $match_0 = d; let x; if ($match_0 === p) { x = e; } else if ...
//
// MatchExpr in ReturnStmt: return match (d) { p => e, ... }
//   → const $match_0 = d; if ($match_0 === p) { return e; } else if ...
//
// Wildcard `_` → else branch
// Or-patterns [p1, p2] → $m === p1 || $m === p2
// Binding patterns (identifier) → const name = $m; prepended to body

import {
	Node, NodeKind,
	BlockStmtData,
	MatchStmtData, MatchExprData, MatchCaseData,
	VariableDeclData, ReturnStmtData, ExprStmtData,
	IdentifierData,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { walkExpandBlocks } from "../walker";
import {
	makeIdent, makeBlock, makeVarDecl, makeExprStmt,
	makeReturn, makeIf, makeBinary, makeAssign,
} from "../util";
import { test, check, testGroup } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerMatch(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandMatchStmt, ctx);
	return program;
}

// Expand a single statement that may contain a match
function expandMatchStmt(stmt: Node, ctx: TransformContext): Node[] {
	// MatchStmt (standalone match statement)
	if (stmt.kind === NodeKind.MatchStmt) {
		return lowerMatchStmt(stmt, ctx);
	}

	// MatchExpr in VariableDecl: const x = match (...) { ... }
	if (stmt.kind === NodeKind.VariableDecl) {
		const d = stmt.data as VariableDeclData;
		if (d.initializer.kind === NodeKind.MatchExpr) {
			return lowerMatchExprInVar(stmt, ctx);
		}
	}

	// MatchExpr in ReturnStmt: return match (...) { ... }
	if (stmt.kind === NodeKind.ReturnStmt) {
		const d = stmt.data as ReturnStmtData;
		if (d.argument.kind === NodeKind.MatchExpr) {
			return lowerMatchExprInReturn(stmt, ctx);
		}
	}

	// MatchExpr as standalone ExprStmt: match (...) { ... };
	if (stmt.kind === NodeKind.ExprStmt) {
		const d = stmt.data as ExprStmtData;
		if (d.expr.kind === NodeKind.MatchStmt) {
			return lowerMatchStmt(d.expr, ctx);
		}
	}

	return [stmt];
}

// ===== MatchStmt → if-else chain =====

function lowerMatchStmt(matchNode: Node, ctx: TransformContext): Node[] {
	const d = matchNode.data as MatchStmtData;
	const loc = matchNode.location;
	const tempName = freshTemp(ctx, "match");
	const result: Node[] = [];

	// const $match_N = discriminant;
	result.push(makeVarDecl(tempName, d.matchStmtDisc, true, loc));

	// Build if-else chain from cases
	const ifChain = buildIfChain(d.matchStmtCases, tempName, loc, false, "");
	result.push(ifChain);

	return result;
}

// ===== MatchExpr in VariableDecl → let x; if-chain with x = armValue =====

function lowerMatchExprInVar(stmt: Node, ctx: TransformContext): Node[] {
	const varData = stmt.data as VariableDeclData;
	const matchData = varData.initializer.data as MatchExprData;
	const loc = stmt.location;
	const tempName = freshTemp(ctx, "match");
	const result: Node[] = [];

	// const $match_N = discriminant;
	result.push(makeVarDecl(tempName, matchData.matchDisc, true, loc));
	// let x; (uninitialized, to be assigned in each branch)
	const placeholder = makeIdent("undefined", loc);
	result.push(makeVarDecl(varData.declName, placeholder, false, loc));
	// if-chain with assignment: x = armValue
	const ifChain = buildIfChain(matchData.matchCases, tempName, loc, true, varData.declName);
	result.push(ifChain);

	return result;
}

// ===== MatchExpr in ReturnStmt → if-chain with return armValue =====

function lowerMatchExprInReturn(stmt: Node, ctx: TransformContext): Node[] {
	const retData = stmt.data as ReturnStmtData;
	const matchData = retData.argument.data as MatchExprData;
	const loc = stmt.location;
	const tempName = freshTemp(ctx, "match");
	const result: Node[] = [];

	// const $match_N = discriminant;
	result.push(makeVarDecl(tempName, matchData.matchDisc, true, loc));
	// if-chain with return: return armValue
	const ifChain = buildIfChainReturn(matchData.matchCases, tempName, loc);
	result.push(ifChain);

	return result;
}

// ===== Build if-else chain =====

// Build if-else chain for statement-context match.
// When isAssign is true, wraps each arm body with `varName = armBody;`
function buildIfChain(cases: Node[], tempName: string, loc: Node["location"], isAssign: boolean, varName: string): Node {
	// Process cases in reverse to build bottom-up if-else chain
	let elseNode = makeBlock([], loc);

	let i = cases.length;
	while (i > 0) {
		i -= 1;
		const caseNode = cases[i];
		const caseData = caseNode.data as MatchCaseData;

		// Build body
		let body: Node = caseData.caseBody;
		if (isAssign) {
			// Wrap as: { varName = caseBody; }
			const assignExpr = makeAssign(makeIdent(varName, loc), caseData.caseBody, loc);
			body = makeBlock([makeExprStmt(assignExpr, loc)], loc);
		}

		// Check if wildcard
		if (isWildcard(caseData.casePatterns)) {
			elseNode = body;
			continue;
		}

		// Check if binding pattern (single identifier that's not a literal/member)
		if (isBindingPattern(caseData.casePatterns)) {
			const bindingName = getBindingName(caseData.casePatterns);
			const bindDecl = makeVarDecl(bindingName, makeIdent(tempName, loc), true, loc);
			// Prepend binding to body
			if (body.kind === NodeKind.BlockStmt) {
				const bodyData = body.data as BlockStmtData;
				const newStmts: Node[] = [];
				newStmts.push(bindDecl);
				for (const s of bodyData.statements) {
					newStmts.push(s);
				}
				body = makeBlock(newStmts, loc);
			} else {
				body = makeBlock([bindDecl, body], loc);
			}
			// Binding always matches (it's like default)
			elseNode = body;
			continue;
		}

		// Build condition from patterns (may be or-patterns)
		const cond = buildPatternCondition(caseData.casePatterns, tempName, loc);
		elseNode = makeIf(cond, body, elseNode, loc);
	}

	return elseNode;
}

// Build if-else chain for return-context match.
function buildIfChainReturn(cases: Node[], tempName: string, loc: Node["location"]): Node {
	let elseNode = makeBlock([], loc);

	let i = cases.length;
	while (i > 0) {
		i -= 1;
		const caseNode = cases[i];
		const caseData = caseNode.data as MatchCaseData;

		// Wrap body: return caseBody;
		const body = makeBlock([makeReturn(caseData.caseBody, loc)], loc);

		if (isWildcard(caseData.casePatterns)) {
			elseNode = body;
			continue;
		}

		if (isBindingPattern(caseData.casePatterns)) {
			const bindingName = getBindingName(caseData.casePatterns);
			const bindDecl = makeVarDecl(bindingName, makeIdent(tempName, loc), true, loc);
			elseNode = makeBlock([bindDecl, makeReturn(caseData.caseBody, loc)], loc);
			continue;
		}

		const cond = buildPatternCondition(caseData.casePatterns, tempName, loc);
		elseNode = makeIf(cond, body, elseNode, loc);
	}

	return elseNode;
}

// ===== Pattern Helpers =====

// Check if pattern list is a wildcard (_)
function isWildcard(patterns: Node[]): boolean {
	if (patterns.length !== 1) return false;
	if (patterns[0].kind !== NodeKind.Identifier) return false;
	const id = patterns[0].data as IdentifierData;
	return id.name === "_";
}

// Check if pattern list is a binding (single identifier, not _, not a literal/member)
function isBindingPattern(patterns: Node[]): boolean {
	if (patterns.length !== 1) return false;
	if (patterns[0].kind !== NodeKind.Identifier) return false;
	const id = patterns[0].data as IdentifierData;
	if (id.name === "_") return false;
	return true;
}

// Get binding name from a binding pattern
function getBindingName(patterns: Node[]): string {
	const id = patterns[0].data as IdentifierData;
	return id.name;
}

// Build condition from pattern list: $m === p1 || $m === p2 || ...
function buildPatternCondition(patterns: Node[], tempName: string, loc: Node["location"]): Node {
	let cond = makePatternTest(patterns[0], tempName, loc);
	let i = 1;
	while (i < patterns.length) {
		const nextTest = makePatternTest(patterns[i], tempName, loc);
		cond = makeBinary(cond, "||", nextTest, loc);
		i += 1;
	}
	return cond;
}

// Build a single pattern test: $m === pattern
function makePatternTest(pattern: Node, tempName: string, loc: Node["location"]): Node {
	return makeBinary(makeIdent(tempName, loc), "===", pattern, loc);
}

// ===== Tests =====

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
