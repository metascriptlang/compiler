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
	Node, NodeKind, DeclKind,
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
	match (stmt.kind) {
		NodeKind.MatchStmt => {
			return lowerMatchStmt(stmt, ctx);
		},
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			if (d.initializer.kind === NodeKind.MatchExpr) {
				return lowerMatchExprInVar(stmt, ctx);
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			if (d.argument.kind === NodeKind.MatchExpr) {
				return lowerMatchExprInReturn(stmt, ctx);
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr.kind === NodeKind.MatchStmt) {
				return lowerMatchStmt(d.expr, ctx);
			}
		},
		_ => {},
	};
	return [stmt];
}

// ===== MatchStmt → if-else chain =====

function lowerMatchStmt(matchNode: Node, ctx: TransformContext): Node[] {
	const d = matchNode.data as MatchStmtData;
	const loc = matchNode.location;
	const tempName = freshTemp(ctx, "match");
	const result: Node[] = [];

	// const $match_N = discriminant;
	result.push(makeVarDecl(tempName, d.matchStmtDisc, DeclKind.Const, loc));

	// Build if-else chain from cases
	const ifChain = buildIfChain(d.matchStmtCases, tempName, loc, "stmt", "");
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
	result.push(makeVarDecl(tempName, matchData.matchDisc, DeclKind.Const, loc));
	// let x; (uninitialized, to be assigned in each branch)
	const placeholder = makeIdent("undefined", loc);
	result.push(makeVarDecl(varData.declName, placeholder, DeclKind.Let, loc));
	// if-chain with assignment: x = armValue
	const ifChain = buildIfChain(matchData.matchCases, tempName, loc, "assign", varData.declName);
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
	result.push(makeVarDecl(tempName, matchData.matchDisc, DeclKind.Const, loc));
	// if-chain with return: return armValue
	const ifChain = buildIfChain(matchData.matchCases, tempName, loc, "return", "");
	result.push(ifChain);

	return result;
}

// ===== Build if-else chain =====
// Unified builder for all match contexts.
// mode: "stmt" = body as-is, "assign" = varName = body, "return" = return body

function buildIfChain(cases: Node[], tempName: string, loc: Node["location"], mode: string, varName: string): Node {
	let elseNode = makeBlock([], loc);

	let i = cases.length;
	while (i > 0) {
		i -= 1;
		const caseNode = cases[i];
		const caseData = caseNode.data as MatchCaseData;

		// Wrap body based on mode
		const body = wrapArmBody(caseData.caseBody, mode, varName, loc);

		if (isWildcard(caseData.casePatterns)) {
			elseNode = body;
			continue;
		}

		if (isBindingPattern(caseData.casePatterns)) {
			const bindingName = getBindingName(caseData.casePatterns);
			const bindDecl = makeVarDecl(bindingName, makeIdent(tempName, loc), DeclKind.Const, loc);
			elseNode = prependToBody(bindDecl, body, loc);
			continue;
		}

		const cond = buildPatternCondition(caseData.casePatterns, tempName, loc);
		elseNode = makeIf(cond, body, elseNode, loc);
	}

	return elseNode;
}

function wrapArmBody(armBody: Node, mode: string, varName: string, loc: Node["location"]): Node {
	return match (mode) {
		"assign" => makeBlock([makeExprStmt(makeAssign(makeIdent(varName, loc), armBody, loc), loc)], loc),
		"return" => makeBlock([makeReturn(armBody, loc)], loc),
		_ => armBody,
	};
}

function prependToBody(decl: Node, body: Node, loc: Node["location"]): Node {
	if (body.kind === NodeKind.BlockStmt) {
		const bodyData = body.data as BlockStmtData;
		const newStmts: Node[] = [];
		newStmts.push(decl);
		for (const s of bodyData.statements) {
			newStmts.push(s);
		}
		return makeBlock(newStmts, loc);
	}
	return makeBlock([decl, body], loc);
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
