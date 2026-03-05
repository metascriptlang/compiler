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
	Node, NodeKind, DeclKind, SourceLocation,
	BlockStmtData,
	MatchStmtData, MatchExprData, MatchCaseData,
	VariableDeclData, ReturnStmtData, ExprStmtData, IfStmtData,
	IdentifierData, NumberLiteralData, StringLiteralData,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { walkExpandBlocks } from "../walker";
import {
	makeIdent, makeTypedIdent, makeBlock, makeVarDecl, makeExprStmt,
	makeReturn, makeIf, makeBinary, makeAssign,
	makeCall, makeNumber, makeSwitch, makeSwitchCase,
} from "../util";
import { Type } from "../../checker/types";
import { check } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";
import { charAt } from "../../utils/string";

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
			if (d.argument !== null && d.argument.kind === NodeKind.MatchExpr) {
				return lowerMatchExprInReturn(stmt, ctx);
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr.kind === NodeKind.MatchStmt) {
				return lowerMatchStmt(d.expr, ctx);
			}
			if (d.expr.kind === NodeKind.MatchExpr) {
				// MatchExpr at statement position (discards value) — lower as stmt
				return lowerMatchExprAsStmt(d.expr, ctx);
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
	const discType = d.matchStmtDisc.nodeType;

	// Build if-else chain from cases
	const ifChain = buildIfChain(d.matchStmtCases, tempName, discType, loc, "stmt", "");
	result.push(ifChain);

	return result;
}

// ===== MatchExpr at statement position (value discarded) =====

function lowerMatchExprAsStmt(matchNode: Node, ctx: TransformContext): Node[] {
	const d = matchNode.data as MatchExprData;
	const loc = matchNode.location;
	const tempName = freshTemp(ctx, "match");
	const result: Node[] = [];
	result.push(makeVarDecl(tempName, d.matchDisc, DeclKind.Const, loc));
	const discType = d.matchDisc.nodeType;
	const ifChain = buildIfChain(d.matchCases, tempName, discType, loc, "stmt", "");
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
	const discType = matchData.matchDisc.nodeType;
	// let x; (uninitialized, to be assigned in each branch)
	const placeholder = makeIdent("undefined", loc);
	const letDecl = makeVarDecl(varData.declName, placeholder, DeclKind.Let, loc);
	if (stmt.nodeType !== null) {
		letDecl.nodeType = stmt.nodeType;
	}
	result.push(letDecl);
	// if-chain with assignment: x = armValue
	const ifChain = buildIfChain(matchData.matchCases, tempName, discType, loc, "assign", varData.declName);
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
	const discType = matchData.matchDisc.nodeType;
	// if-chain with return: return armValue
	const ifChain = buildIfChain(matchData.matchCases, tempName, discType, loc, "return", "");
	result.push(ifChain);

	return result;
}

// ===== Build if-else chain =====
// Unified builder for all match contexts.
// mode: "stmt" = body as-is, "assign" = varName = body, "return" = return body

function buildIfChain(cases: Node[], tempName: string, discType: Type, loc: SourceLocation, mode: string, varName: string): Node {
	// String hash dispatch for >8 string cases
	if (isAllStringCases(cases)) {
		return buildHashSwitch(cases, tempName, discType, loc, mode, varName);
	}

	// Check if any case is a wildcard/binding — if not, last arm becomes the else
	let hasDefault = false;
	for (let ci = 0; ci < cases.length; ci += 1) {
		const cd = cases[ci].data as MatchCaseData;
		if (isWildcard(cd.casePatterns) || isBindingPattern(cd.casePatterns)) { hasDefault = true; }
	}

	let elseNode = makeBlock([], loc);

	for (let i = cases.length - 1; i >= 0; i -= 1) {
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
			const bindDecl = makeVarDecl(bindingName, makeTypedIdent(tempName, discType, loc), DeclKind.Const, loc);
			elseNode = prependToBody(bindDecl, body, loc);
			continue;
		}

		// No wildcard and this is the last arm → use as unconditional else
		// (checker verified exhaustiveness, so this is safe)
		if (!hasDefault && i === cases.length - 1) {
			elseNode = body;
			continue;
		}

		const cond = buildPatternCondition(caseData.casePatterns, tempName, discType, loc);
		elseNode = makeIf(cond, body, elseNode, loc);
	}

	return elseNode;
}

// ===== moveInto — Unified Result Destination Insertion =====
// Nim pattern: jsgen.nim moveInto + semexprs.nim
// Pushes the "result destination" (return or assignment) into terminal positions.
// C has no expression-blocks — this makes each arm produce a statement-level result.

function wrapArmBody(armBody: Node, mode: string, varName: string, loc: SourceLocation): Node {
	if (mode === "stmt") return armBody;
	return moveInto(armBody, mode, varName, loc);
}

// Recursive: walks into blocks and if-else to find terminal expressions.
// Returns a new node with return/assign inserted at every terminal position.
function moveInto(node: Node, mode: string, varName: string, loc: SourceLocation): Node {
	// BlockStmt: keep leading stmts, moveInto the last one
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		if (bd.statements.length === 0) return node;
		const newStmts: Node[] = [];
		let si = 0;
		while (si < bd.statements.length - 1) {
			newStmts.push(bd.statements[si]);
			si = si + 1;
		}
		newStmts.push(moveInto(bd.statements[bd.statements.length - 1], mode, varName, loc));
		return makeBlock(newStmts, loc);
	}
	// IfStmt: recurse into both branches
	if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		d.consequent = moveInto(d.consequent, mode, varName, loc);
		if (d.alternate !== null) {
			d.alternate = moveInto(d.alternate, mode, varName, loc);
		}
		return node;
	}
	// ExprStmt: unwrap and wrap in return/assign
	if (node.kind === NodeKind.ExprStmt) {
		const expr = (node.data as ExprStmtData).expr;
		return emitResult(expr, mode, varName, loc);
	}
	// Bare expression (not wrapped in ExprStmt): wrap directly
	return emitResult(node, mode, varName, loc);
}

// Emit the final result: either return expr or varName = expr
function emitResult(expr: Node, mode: string, varName: string, loc: SourceLocation): Node {
	if (mode === "return") {
		return makeReturn(expr, loc);
	}
	return makeExprStmt(makeAssign(makeIdent(varName, loc), expr, loc), loc);
}

function prependToBody(decl: Node, body: Node, loc: SourceLocation): Node {
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

// Check if pattern list is a binding (single identifier, not _, not a literal/member/enum-rewrite)
function isBindingPattern(patterns: Node[]): boolean {
	if (patterns.length !== 1) return false;
	if (patterns[0].kind !== NodeKind.Identifier) return false;
	const id = patterns[0].data as IdentifierData;
	if (id.name === "_") return false;
	// If the identifier has a resolvedSym, it's an enum value (rewritten from MemberExpr by checker), not a binding
	if (patterns[0].resolvedSym !== null) return false;
	return true;
}

// Get binding name from a binding pattern
function getBindingName(patterns: Node[]): string {
	const id = patterns[0].data as IdentifierData;
	return id.name;
}

// Build condition from pattern list: $m === p1 || $m === p2 || ...
function buildPatternCondition(patterns: Node[], tempName: string, discType: Type, loc: SourceLocation): Node {
	let cond = makePatternTest(patterns[0], tempName, discType, loc);
	for (let i = 1; i < patterns.length; i += 1) {
		const nextTest = makePatternTest(patterns[i], tempName, discType, loc);
		cond = makeBinary(cond, "||", nextTest, loc);
	}
	return cond;
}

// Build a single pattern test: $m === pattern
function makePatternTest(pattern: Node, tempName: string, discType: Type, loc: SourceLocation): Node {
	return makeBinary(makeTypedIdent(tempName, discType, loc), "===", pattern, loc);
}

// ===== String Hash Dispatch =====
// When ALL non-wildcard/non-binding arms are string literals and count > 8,
// emit switch(djb2(disc)) with equality guards instead of if-else chain.
// Matches Nim's genStringCase optimization (ccgstmts.nim).

const STRING_HASH_THRESHOLD: number = 8;

// DJB2 hash — must match C runtime's msStringHash for correctness.
// Note: .code only works on string literals (DRC #28), so we use charCodeAt helper.
function djb2Hash(s: string): number {
	let h: number = 5381;
	let i = 0;
	while (i < s.length) {
		const cc = charCodeAt(s, i);
		// h = h * 33 + charCode
		h = ((h * 33) + cc) | 0;
		i = i + 1;
	}
	return h;
}

// Get char code at position — workaround for .code only working on literals.
function charCodeAt(s: string, idx: number): number {
	const ch = charAt(s, idx);
	// Map ASCII printable range. For hash dispatch, we only need string literal chars.
	if (ch === " ") return 32;
	if (ch === "!") return 33;
	if (ch === "\"") return 34;
	if (ch === "#") return 35;
	if (ch === "$") return 36;
	if (ch === "%") return 37;
	if (ch === "&") return 38;
	if (ch === "'") return 39;
	if (ch === "(") return 40;
	if (ch === ")") return 41;
	if (ch === "*") return 42;
	if (ch === "+") return 43;
	if (ch === ",") return 44;
	if (ch === "-") return 45;
	if (ch === ".") return 46;
	if (ch === "/") return 47;
	if (ch === "0") return 48;
	if (ch === "1") return 49;
	if (ch === "2") return 50;
	if (ch === "3") return 51;
	if (ch === "4") return 52;
	if (ch === "5") return 53;
	if (ch === "6") return 54;
	if (ch === "7") return 55;
	if (ch === "8") return 56;
	if (ch === "9") return 57;
	if (ch === ":") return 58;
	if (ch === ";") return 59;
	if (ch === "<") return 60;
	if (ch === "=") return 61;
	if (ch === ">") return 62;
	if (ch === "?") return 63;
	if (ch === "@") return 64;
	// Uppercase A-Z
	if (ch === "A") return 65;
	if (ch === "B") return 66;
	if (ch === "C") return 67;
	if (ch === "D") return 68;
	if (ch === "E") return 69;
	if (ch === "F") return 70;
	if (ch === "G") return 71;
	if (ch === "H") return 72;
	if (ch === "I") return 73;
	if (ch === "J") return 74;
	if (ch === "K") return 75;
	if (ch === "L") return 76;
	if (ch === "M") return 77;
	if (ch === "N") return 78;
	if (ch === "O") return 79;
	if (ch === "P") return 80;
	if (ch === "Q") return 81;
	if (ch === "R") return 82;
	if (ch === "S") return 83;
	if (ch === "T") return 84;
	if (ch === "U") return 85;
	if (ch === "V") return 86;
	if (ch === "W") return 87;
	if (ch === "X") return 88;
	if (ch === "Y") return 89;
	if (ch === "Z") return 90;
	if (ch === "[") return 91;
	if (ch === "\\") return 92;
	if (ch === "]") return 93;
	if (ch === "^") return 94;
	if (ch === "_") return 95;
	if (ch === "`") return 96;
	// Lowercase a-z
	if (ch === "a") return 97;
	if (ch === "b") return 98;
	if (ch === "c") return 99;
	if (ch === "d") return 100;
	if (ch === "e") return 101;
	if (ch === "f") return 102;
	if (ch === "g") return 103;
	if (ch === "h") return 104;
	if (ch === "i") return 105;
	if (ch === "j") return 106;
	if (ch === "k") return 107;
	if (ch === "l") return 108;
	if (ch === "m") return 109;
	if (ch === "n") return 110;
	if (ch === "o") return 111;
	if (ch === "p") return 112;
	if (ch === "q") return 113;
	if (ch === "r") return 114;
	if (ch === "s") return 115;
	if (ch === "t") return 116;
	if (ch === "u") return 117;
	if (ch === "v") return 118;
	if (ch === "w") return 119;
	if (ch === "x") return 120;
	if (ch === "y") return 121;
	if (ch === "z") return 122;
	if (ch === "{") return 123;
	if (ch === "|") return 124;
	if (ch === "}") return 125;
	if (ch === "~") return 126;
	return 0;
}

// Check if all non-wildcard/non-binding patterns are string literals.
function isAllStringCases(cases: Node[]): boolean {
	let stringCount = 0;
	for (let i = 0; i < cases.length; i += 1) {
		const caseData = cases[i].data as MatchCaseData;
		if (isWildcard(caseData.casePatterns)) continue;
		if (isBindingPattern(caseData.casePatterns)) return false;
		// Check all patterns in this arm are string literals
		for (let j = 0; j < caseData.casePatterns.length; j += 1) {
			if (caseData.casePatterns[j].kind !== NodeKind.StringLiteral) return false;
		}
		stringCount = stringCount + 1;
	}
	return stringCount > STRING_HASH_THRESHOLD;
}

// Build switch(djb2(disc)) { case HASH: if (disc === str) { body } break; ... default: { wildcard } }
function buildHashSwitch(cases: Node[], tempName: string, discType: Type, loc: SourceLocation, mode: string, varName: string): Node {
	const switchCases: Node[] = [];
	let defaultBody = makeBlock([], loc);

	for (let i = 0; i < cases.length; i += 1) {
		const caseData = cases[i].data as MatchCaseData;
		if (isWildcard(caseData.casePatterns)) {
			defaultBody = wrapArmBody(caseData.caseBody, mode, varName, loc);
			continue;
		}

		// Each pattern gets its own switch case (hash value)
		for (let j = 0; j < caseData.casePatterns.length; j += 1) {
			const pat = caseData.casePatterns[j];
			const strData = pat.data as StringLiteralData;
			const hash = djb2Hash(strData.value);

			// Body: if (temp === "literal") { armBody; break; }
			const body = wrapArmBody(caseData.caseBody, mode, varName, loc);
			const guard = makeBinary(makeTypedIdent(tempName, discType, loc), "===", pat, loc);
			const guardedBody = makeIf(guard, body, makeBlock([], loc), loc);
			const caseStmts: Node[] = [];
			caseStmts.push(guardedBody);

			const hashNode = makeNumber(hash, loc);
			const tests: Node[] = [];
			tests.push(hashNode);
			switchCases.push(makeSwitchCase(tests, caseStmts, false, loc));
		}
	}

	// Default case
	const defaultStmts: Node[] = [];
	defaultStmts.push(defaultBody);
	switchCases.push(makeSwitchCase([], defaultStmts, true, loc));

	// switch (msStringHash(temp))
	const hashCallArgs: Node[] = [];
	hashCallArgs.push(makeTypedIdent(tempName, discType, loc));
	const hashCall = makeCall(makeIdent("msStringHash", loc), hashCallArgs, loc);
	return makeSwitch(hashCall, switchCases, loc);
}

// ===== Tests =====
test "match stmt becomes if chain" { check(stmtCountAfter("match (x) { 1 => foo(), _ => bar() }", lowerMatch) === 2); }

test "match first stmt is VarDecl (discriminant temp)" { check(firstStmtKindAfter("match (x) { 1 => a(), _ => b() }", lowerMatch) === NodeKind.VariableDecl); }

test "no match passthrough" { check(stmtCountAfter("const x = 1;", lowerMatch) === 1); }

test "match preserves surrounding stmts" { check(stmtCountAfter("let a = 1; match (x) { _ => b() } let c = 2;", lowerMatch) === 4); }

test "string hash dispatch for >8 arms" {
	const src = "match (x) { \"a\" => 1, \"b\" => 2, \"c\" => 3, \"d\" => 4, \"e\" => 5, \"f\" => 6, \"g\" => 7, \"h\" => 8, \"i\" => 9, _ => 0 }";
	// 9 string arms > threshold(8) → should produce SwitchStmt (2nd stmt after VarDecl temp)
	check(stmtCountAfter(src, lowerMatch) === 2);
}

test "few string arms stay as if-else" {
	const src = "match (x) { \"a\" => 1, \"b\" => 2, _ => 0 }";
	// 2 string arms <= threshold → stays as if-else chain
	check(stmtCountAfter(src, lowerMatch) === 2);
}

test "djb2 hash deterministic" {
	check(djb2Hash("hello") === djb2Hash("hello"));
	check(djb2Hash("a") !== djb2Hash("b"));
}
