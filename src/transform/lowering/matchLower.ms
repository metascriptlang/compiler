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

import { Node, NodeKind, DeclKind, TypeKind, SourceLocation, BlockStmtData, MatchStmtData, MatchExprData, MatchCaseData, MemberExprData, VariableDeclData, ReturnStmtData, ExprStmtData, IfStmtData, IdentifierData, NumberLiteralData, ArrowFunctionData, StringLiteralData, Type, Symbol, SymbolKind, isEmptyBlock } from "../../ast/node";
import { TransformContext, freshTempSym, reportTransformError } from "../context";
import { walkExpandBlocksHooked, containsExprKind } from "../walker";
import { hoistGuarded, expandConditionStmt } from "./guardedLower";
import { frameReach } from "./operandOrder";
import {
	makeIdentResolved, makeTypedIdentResolved, makeBlock, makeVarDecl, makeExprStmt, makeNull,
	makeReturn, makeIf, makeBinary, makeAssign, makeBool, makeUnary,
	makeCall, makeNumber, makeSwitch, makeSwitchCase, isCSwitchableType, runtimeRef,
} from "../util";
import { booleanType, int32Type } from "../../checker/types";
import { stmtCountAfter, firstStmtKindAfter, parseInput, makeCtx, getStmts } from "../testUtil";
import { hashStringSigned } from "std/hash";
import { endsInNoReturn } from "../analysis/dce";

enum ArmMode {
	Stmt,
	Assign,
	Return,
}

// ===== Nested MatchExpr Hoisting =====

function hoistNestedMatch(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	return hoistGuarded(expr, NodeKind.MatchExpr, hoistMatchExpr, hoisted, ctx);
}

function hoistMatchExpr(node: Node, hoisted: Node[], ctx: TransformContext): Node {
	const matchData = node.data as MatchExprData;
	matchData.matchDisc = hoistNestedMatch(matchData.matchDisc, hoisted, ctx);
	const loc = node.location;
	const resultSym = freshTempSym(ctx, "matchres", node.nodeType);

	const placeholder = makeNull(loc);
	const letDecl = makeVarDecl(resultSym.name, placeholder, DeclKind.Let, loc);
	letDecl.resolvedSym = resultSym;
	if (node.nodeType != null) { letDecl.nodeType = node.nodeType; }
	hoisted.push(letDecl);

	for (const s of distributeMatch(node, ArmMode.Assign, resultSym, ctx)) {
		hoisted.push(s);
	}

	return makeIdentResolved(resultSym, loc);
}

// ===== Main Entry Point =====

export function lowerMatch(program: Node, ctx: TransformContext): Node {
	const outer = ctx.frameReach;
	ctx.frameReach = frameReach(program, NodeKind.MatchExpr);
	walkExpandBlocksHooked(program, expandMatchStmt, ctx, returnArrowBodyMatch, null);
	ctx.frameReach = outer;
	return program;
}

function returnArrowBodyMatch(fn: Node): void {
	if (fn.kind != NodeKind.ArrowFunction) return;
	const d = fn.data as ArrowFunctionData;
	if (d.arrowBody.kind == NodeKind.BlockStmt || !containsExprKind(d.arrowBody, NodeKind.MatchExpr)) return;
	d.arrowBody = makeBlock([makeReturn(d.arrowBody, d.arrowBody.location)], d.arrowBody.location);
}

function expandMatchStmt(stmt: Node, ctx: TransformContext): Node[] {
	match (stmt.kind) {
		NodeKind.MatchStmt => {
			return lowerMatchStmt(stmt, ctx);
		},
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			if (d.initializer != null && d.initializer.kind == NodeKind.MatchExpr) {
				return lowerMatchExprInVar(stmt, ctx);
			}
			if (d.initializer != null && containsExprKind(d.initializer, NodeKind.MatchExpr)) {
				const hoisted: Node[] = [];
				d.initializer = hoistNestedMatch(d.initializer, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			if (d.argument != null && d.argument.kind == NodeKind.MatchExpr) {
				return distributeMatch(d.argument, ArmMode.Return, null, ctx);
			}
			if (d.argument != null && containsExprKind(d.argument, NodeKind.MatchExpr)) {
				const hoisted: Node[] = [];
				d.argument = hoistNestedMatch(d.argument, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr.kind == NodeKind.MatchStmt) {
				return lowerMatchStmt(d.expr, ctx);
			}
			if (d.expr.kind == NodeKind.MatchExpr) {
				return lowerMatchExprAsStmt(d.expr, ctx);
			}
			if (containsExprKind(d.expr, NodeKind.MatchExpr)) {
				const hoisted: Node[] = [];
				d.expr = hoistNestedMatch(d.expr, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.IfStmt | NodeKind.WhileStmt | NodeKind.DoWhileStmt | NodeKind.ForStmt | NodeKind.SwitchStmt | NodeKind.AssertStmt => {
			return expandConditionStmt(stmt, NodeKind.MatchExpr, hoistMatchExpr, ctx);
		},
		_ => {},
	};
	return [stmt];
}

export function lowerMatchStmt(matchNode: Node, ctx: TransformContext): Node[] {
	const d = matchNode.data as MatchStmtData;
	const loc = matchNode.location;
	const matchSym = freshTempSym(ctx, "match", d.matchStmtDisc.nodeType);
	const result: Node[] = [];

	const matchDecl = makeVarDecl(matchSym.name, d.matchStmtDisc, DeclKind.Const, loc);
	matchDecl.resolvedSym = matchSym;
	result.push(matchDecl);
	result.push(buildIfChain(d.matchStmtCases, matchSym, d.matchStmtDisc.nodeType, loc, ArmMode.Stmt, null, ctx));
	return result;
}

function lowerMatchExprAsStmt(matchNode: Node, ctx: TransformContext): Node[] {
	return distributeMatch(matchNode, ArmMode.Stmt, null, ctx);
}

function lowerMatchExprInVar(stmt: Node, ctx: TransformContext): Node[] {
	const varData = stmt.data as VariableDeclData;
	const loc = stmt.location;
	if (stmt.resolvedSym == null) {
		if (stmt.nodeType == null) return [stmt];
		throw new Error(`internal: match initializer of '${varData.declName}' reached lowering without its symbol`);
	}
	const result: Node[] = [];
	const placeholder = makeNull(loc);
	const letDecl = makeVarDecl(varData.declName, placeholder, DeclKind.Let, loc);
	letDecl.resolvedSym = stmt.resolvedSym;
	if (stmt.nodeType != null) {
		letDecl.nodeType = stmt.nodeType;
	}
	result.push(letDecl);
	for (const s of distributeMatch(varData.initializer, ArmMode.Assign, stmt.resolvedSym, ctx)) {
		result.push(s);
	}
	return result;
}

function distributeMatch(matchNode: Node, mode: ArmMode, assignSym: Symbol | null, ctx: TransformContext): Node[] {
	const d = matchNode.data as MatchExprData;
	const loc = matchNode.location;
	const matchSym = freshTempSym(ctx, "match", d.matchDisc.nodeType);
	const matchDecl = makeVarDecl(matchSym.name, d.matchDisc, DeclKind.Const, loc);
	matchDecl.resolvedSym = matchSym;
	return [matchDecl, buildIfChain(d.matchCases, matchSym, d.matchDisc.nodeType, loc, mode, assignSym, ctx)];
}

// ===== Build if-else chain =====

// Guards are allowed: they become if-chains inside switch case bodies.
function canUseSwitchDispatch(cases: Node[], discType: Type | null): boolean {
	if (!isCSwitchableType(discType)) return false;
	for (let i = 0; i < cases.length; i += 1) {
		const cd = cases[i].data as MatchCaseData;
		if (isWildcard(cd.casePatterns)) continue;
		if (isBindingPattern(cd.casePatterns)) return false;
		for (let j = 0; j < cd.casePatterns.length; j += 1) {
			const p = cd.casePatterns[j];
			if (p.kind == NodeKind.NumberLiteral) continue;
			if (p.kind == NodeKind.Identifier && p.resolvedSym != null) {
				if (p.resolvedSym.symbolKind == SymbolKind.EnumMember) continue;
				return false;
			}
			if (p.kind == NodeKind.MemberExpr) {
				const objectType = (p.data as MemberExprData).object.nodeType;
				if (objectType != null && objectType.kind == TypeKind.Enum) continue;
				return false;
			}
			if (p.kind == NodeKind.UnaryExpr) continue;
			return false;
		}
	}
	return true;
}

function buildSwitchDispatch(cases: Node[], matchSym: Symbol, discType: Type | null, loc: SourceLocation, mode: ArmMode, assignSym: Symbol | null, ctx: TransformContext): Node {
	let defaultBody = makeBlock([], loc);
	for (let wi = cases.length - 1; wi >= 0; wi -= 1) {
		const wd = cases[wi].data as MatchCaseData;
		if (!isWildcard(wd.casePatterns)) continue;
		const body = wrapArmBody(wd.caseBody, mode, assignSym, loc, ctx);
		if (wd.caseGuard != null) {
			defaultBody = makeIf(wd.caseGuard, body, defaultBody, loc);
		} else {
			defaultBody = body;
		}
	}

	// The $matched flag gates only a non-empty default body that arms cannot early-return past.
	const needsFlag = mode != ArmMode.Return && !isEmptyBlock(defaultBody);
	const matchedSym = freshTempSym(ctx, "matched", booleanType());
	const matchedName = matchedSym.name;

	// Arms with the identical pattern set (`A | B` equals `B | A`) merge into one SwitchCase
	// with a guard chain. A partial overlap (`A | B => x; A when g => y`) is an error: merging
	// would run the second body on labels it does not match, and separate cases would emit
	// duplicate C labels.
	const groupBySet = new Map<string, int32>();
	const groupByLabel = new Map<string, int32>();
	const patternTests: Node[][] = [];
	const armGuards: (Node | null)[][] = [];
	const armBodies: Node[][] = [];

	for (let i = 0; i < cases.length; i += 1) {
		const caseData = cases[i].data as MatchCaseData;
		if (isWildcard(caseData.casePatterns)) continue;

		const setKey = patternSetKey(caseData.casePatterns, i);

		const mergedInto = groupBySet.get(setKey);

		if (mergedInto == null) {
			for (const pat of caseData.casePatterns) {
				const lk = patternKey(pat, i);
				if (groupByLabel.has(lk)) {
					reportTransformError(ctx, "match: duplicate case label '" + lk + "' — pattern overlaps a previous arm with a different pattern set; use either identical or non-overlapping arms", pat.location);
				}
			}
		}

		const armBody = wrapArmBody(caseData.caseBody, mode, assignSym, loc, ctx);

		if (mergedInto != null) {
			armGuards[mergedInto].push(caseData.caseGuard);
			armBodies[mergedInto].push(armBody);
		} else {
			const newGroup = patternTests.length;
			groupBySet.set(setKey, newGroup);
			patternTests.push(caseData.casePatterns);
			armGuards.push([caseData.caseGuard]);
			armBodies.push([armBody]);
			for (const pat of caseData.casePatterns) {
				groupByLabel.set(patternKey(pat, i), newGroup);
			}
		}
	}

	const switchCases: Node[] = [];
	for (let gi = 0; gi < patternTests.length; gi += 1) {
		const guards = armGuards[gi];
		const bodies = armBodies[gi];
		const caseStmts: Node[] = [];

		// Chain guard-body pairs as if/else-if/else — first-match-wins. Built
		// back to front; an unguarded arm terminates the chain (arms after it
		// are unreachable). Sibling `if`s with empty elses ran EVERY arm whose
		// guard held plus the unguarded sibling (bug080: assign mode overwrote
		// the matched result, stmt mode ran two bodies).
		let chained: Node = makeBlock([], loc);
		for (let ai = guards.length - 1; ai >= 0; ai -= 1) {
			let armBody = bodies[ai];
			if (needsFlag) {
				const setMatched = makeExprStmt(makeAssign(makeIdentResolved(matchedSym, loc), makeBool(true, loc), loc), loc);
				armBody = makeBlock([setMatched, armBody], loc);
			}
			const guard = guards[ai];
			if (guard != null) {
				chained = makeIf(guard, armBody, chained, loc);
			} else {
				chained = armBody;
			}
		}
		caseStmts.push(chained);

		switchCases.push(makeSwitchCase(patternTests[gi], caseStmts, false, loc));
	}

	const discIdent = makeTypedIdentResolved(matchSym, discType, loc);
	const switchNode = makeSwitch(discIdent, switchCases, loc);

	const stmts: Node[] = [];
	if (needsFlag) {
		const matchedDecl = makeVarDecl(matchedName, makeBool(false, loc), DeclKind.Let, loc);
		matchedDecl.resolvedSym = matchedSym;
		stmts.push(matchedDecl);
		stmts.push(switchNode);
		const notMatched = makeUnary("!", makeIdentResolved(matchedSym, loc), loc);
		stmts.push(makeIf(notMatched, defaultBody, makeBlock([], loc), loc));
	} else {
		stmts.push(switchNode);
		if (!isEmptyBlock(defaultBody)) {
			stmts.push(defaultBody);
		}
	}
	return makeBlock(stmts, loc);
}

function buildIfChain(cases: Node[], matchSym: Symbol, discType: Type | null, loc: SourceLocation, mode: ArmMode, assignSym: Symbol | null, ctx: TransformContext): Node {
	if (!ctx.raiserBackend && isAllStringCases(cases)) {
		return buildHashSwitch(cases, matchSym, discType, loc, mode, assignSym, ctx);
	}

	if (canUseSwitchDispatch(cases, discType)) {
		return buildSwitchDispatch(cases, matchSym, discType, loc, mode, assignSym, ctx);
	}

	let elseNode = makeBlock([], loc);

	for (let i = cases.length - 1; i >= 0; i -= 1) {
		const caseNode = cases[i];
		const caseData = caseNode.data as MatchCaseData;

		const body = wrapArmBody(caseData.caseBody, mode, assignSym, loc, ctx);

		if (isWildcard(caseData.casePatterns)) {
			if (caseData.caseGuard != null) {
				elseNode = makeIf(caseData.caseGuard, body, elseNode, loc);
			} else {
				elseNode = body;
			}
			continue;
		}

		if (isBindingPattern(caseData.casePatterns)) {
			const bindingName = getBindingName(caseData.casePatterns);
			const bindDecl = makeVarDecl(bindingName, makeTypedIdentResolved(matchSym, discType, loc), DeclKind.Const, loc);
			if (caseData.caseGuard != null) {
				const guardedBody = makeIf(caseData.caseGuard, body, elseNode, loc);
				elseNode = prependToBody(bindDecl, guardedBody, loc);
			} else {
				elseNode = prependToBody(bindDecl, body, loc);
			}
			continue;
		}

		let cond = buildPatternCondition(caseData.casePatterns, matchSym, discType, loc);
		if (caseData.caseGuard != null) {
			cond = makeBinary(cond, "&&", caseData.caseGuard, loc);
		}
		elseNode = makeIf(cond, body, elseNode, loc);
	}

	return elseNode;
}

// ===== moveInto — result destination insertion =====
// C has no expression-blocks: the return or assignment moves into each terminal position.

function wrapArmBody(armBody: Node, mode: ArmMode, assignSym: Symbol | null, loc: SourceLocation, ctx: TransformContext): Node {
	if (armBody.kind == NodeKind.MatchExpr) {
		return makeBlock(distributeMatch(armBody, mode, assignSym, ctx), loc);
	}
	return match (mode) {
		ArmMode.Stmt => {
			if (armBody.kind != NodeKind.BlockStmt && armBody.kind != NodeKind.ExprStmt
				&& armBody.kind != NodeKind.IfStmt && armBody.kind != NodeKind.ReturnStmt
				&& armBody.kind != NodeKind.BreakStmt && armBody.kind != NodeKind.ContinueStmt
				&& armBody.kind != NodeKind.ThrowStmt && armBody.kind != NodeKind.VariableDecl) {
				return makeExprStmt(armBody, loc);
			}
			return armBody;
		},
		ArmMode.Assign | ArmMode.Return => moveInto(armBody, mode, assignSym, loc, ctx),
	};
}

function moveInto(node: Node, mode: ArmMode, assignSym: Symbol | null, loc: SourceLocation, ctx: TransformContext): Node {
	if (node.kind == NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		if (bd.statements.length == 0) return node;
		const newStmts: Node[] = [];
		let si = 0;
		while (si < bd.statements.length - 1) {
			newStmts.push(bd.statements[si]);
			si = si + 1;
		}
		newStmts.push(moveInto(bd.statements[bd.statements.length - 1], mode, assignSym, loc, ctx));
		return makeBlock(newStmts, loc);
	}
	if (node.kind == NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		d.consequent = moveInto(d.consequent, mode, assignSym, loc, ctx);
		if (d.alternate != null) {
			d.alternate = moveInto(d.alternate, mode, assignSym, loc, ctx);
		}
		return node;
	}
	if (endsInNoReturn(node, ctx)) return node;
	if (node.kind == NodeKind.ExprStmt) {
		const expr = (node.data as ExprStmtData).expr;
		return moveInto(expr, mode, assignSym, loc, ctx);
	}
	if (node.kind == NodeKind.MatchExpr) {
		return makeBlock(distributeMatch(node, mode, assignSym, ctx), loc);
	}
	return emitResult(node, mode, assignSym, loc);
}

// A noreturn arm yields no value: emit the bare call.
function emitResult(expr: Node, mode: ArmMode, assignSym: Symbol | null, loc: SourceLocation): Node {
	if (expr.nodeType != null && expr.nodeType.kind == TypeKind.Never) {
		return makeExprStmt(expr, loc);
	}
	return match (mode) {
		ArmMode.Return => makeReturn(expr, loc),
		ArmMode.Assign => {
			if (assignSym == null) throw new Error("internal: a match arm assigns to a binding that has no symbol");
			return makeExprStmt(makeAssign(makeIdentResolved(assignSym, loc), expr, loc), loc);
		},
		ArmMode.Stmt => {
			throw new Error("internal: a statement-mode match arm reached result insertion");
		},
	};
}

function prependToBody(decl: Node, body: Node, loc: SourceLocation): Node {
	if (body.kind == NodeKind.BlockStmt) {
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

function isWildcard(patterns: Node[]): boolean {
	if (patterns.length != 1) return false;
	if (patterns[0].kind != NodeKind.Identifier) return false;
	const id = patterns[0].data as IdentifierData;
	return id.name == "_";
}

function isBindingPattern(patterns: Node[]): boolean {
	if (patterns.length != 1) return false;
	if (patterns[0].kind != NodeKind.Identifier) return false;
	const id = patterns[0].data as IdentifierData;
	if (id.name == "_") return false;
	// If the identifier has a resolvedSym, it's an enum value (rewritten from MemberExpr by checker), not a binding
	if (patterns[0].resolvedSym != null) return false;
	return true;
}

function getBindingName(patterns: Node[]): string {
	const id = patterns[0].data as IdentifierData;
	return id.name;
}

function patternKey(pat: Node, caseIdx: int32): string {
	return match (pat.kind) {
		NodeKind.NumberLiteral => `n:${(pat.data as NumberLiteralData).value}`,
		NodeKind.Identifier => "id:" + (pat.data as IdentifierData).name,
		NodeKind.MemberExpr => {
			if (pat.resolvedSym != null) return "sym:" + pat.resolvedSym.name;
			return "m:" + (pat.data as MemberExprData).property;
		},
		// A key no other pattern shares, so the arm never merges.
		_ => `x:${caseIdx}`,
	};
}

function patternSetKey(patterns: Node[], caseIdx: int32): string {
	const keys: string[] = [];
	for (const pat of patterns) {
		keys.push(patternKey(pat, caseIdx));
	}
	keys.sort();
	return keys.join("|");
}

function buildPatternCondition(patterns: Node[], matchSym: Symbol, discType: Type | null, loc: SourceLocation): Node {
	let cond = makePatternTest(patterns[0], matchSym, discType, loc);
	for (let i = 1; i < patterns.length; i += 1) {
		const nextTest = makePatternTest(patterns[i], matchSym, discType, loc);
		cond = makeBinary(cond, "||", nextTest, loc);
	}
	return cond;
}

function makePatternTest(pattern: Node, matchSym: Symbol, discType: Type | null, loc: SourceLocation): Node {
	return makeBinary(makeTypedIdentResolved(matchSym, discType, loc), "===", pattern, loc);
}

// ===== String Hash Dispatch =====
// When all non-wildcard arms are string literals holding more than STRING_HASH_THRESHOLD labels,
// emit a switch on msStringHash(disc) with equality checks in place of an if-else chain.

const STRING_HASH_THRESHOLD: int32 = 8;

function isAllStringCases(cases: Node[]): boolean {
	let stringCount = 0;
	for (let i = 0; i < cases.length; i += 1) {
		const caseData = cases[i].data as MatchCaseData;
		// Hash dispatch has no guard support — buildHashSwitch matches on
		// string equality alone and would DROP a `when` guard silently.
		// Guarded matches take the if-chain path instead (correct, unoptimized).
		if (caseData.caseGuard != null) return false;
		if (isWildcard(caseData.casePatterns)) continue;
		if (isBindingPattern(caseData.casePatterns)) return false;
		for (let j = 0; j < caseData.casePatterns.length; j += 1) {
			if (caseData.casePatterns[j].kind != NodeKind.StringLiteral) return false;
		}
		stringCount = stringCount + caseData.casePatterns.length;
	}
	return stringCount > STRING_HASH_THRESHOLD;
}

interface HashBucket {
	hash: int32;
	tests: Node[];
	arms: int32[];
}

function buildHashSwitch(cases: Node[], matchSym: Symbol, discType: Type | null, loc: SourceLocation, mode: ArmMode, assignSym: Symbol | null, ctx: TransformContext): Node {
	let defaultBody = makeBlock([], loc);
	const armTests: Node[][] = [];
	const armBodies: Node[] = [];
	const buckets: HashBucket[] = [];

	for (const c of cases) {
		const caseData = c.data as MatchCaseData;
		const body = wrapArmBody(caseData.caseBody, mode, assignSym, loc, ctx);
		if (isWildcard(caseData.casePatterns)) {
			defaultBody = body;
			continue;
		}
		const arm = armBodies.length;
		armBodies.push(body);
		if (ctx.jsBackend) {
			armTests.push(caseData.casePatterns);
			continue;
		}
		armTests.push([makeNumber(arm, loc)]);
		for (const pat of caseData.casePatterns) {
			const hash = hashStringSigned((pat.data as StringLiteralData).value);
			let bucket = -1;
			for (let bi = 0; bi < buckets.length; bi += 1) {
				if (buckets[bi].hash == hash) {
					bucket = bi;
					break;
				}
			}
			if (bucket < 0) {
				bucket = buckets.length;
				buckets.push({ hash, tests: [], arms: [] });
			}
			buckets[bucket].tests.push(pat);
			buckets[bucket].arms.push(arm);
		}
	}

	const defaultInSwitch = mode != ArmMode.Return && !isEmptyBlock(defaultBody);
	const dispatchCases: Node[] = [];
	for (let arm = 0; arm < armBodies.length; arm += 1) {
		dispatchCases.push(makeSwitchCase(armTests[arm], [armBodies[arm]], false, loc));
	}
	if (defaultInSwitch) {
		dispatchCases.push(makeSwitchCase([], [defaultBody], true, loc));
	}

	const stmts: Node[] = [];
	const discNode = makeTypedIdentResolved(matchSym, discType, loc);
	if (ctx.jsBackend) {
		stmts.push(makeSwitch(discNode, dispatchCases, loc));
	} else {
		const armSym = freshTempSym(ctx, "arm", int32Type());
		const armDecl = makeVarDecl(armSym.name, makeNumber(-1, loc), DeclKind.Let, loc);
		armDecl.resolvedSym = armSym;
		stmts.push(armDecl);
		const hashCases: Node[] = [];
		for (const bucket of buckets) {
			let chain: Node = makeBlock([], loc);
			for (let ti = bucket.tests.length - 1; ti >= 0; ti -= 1) {
				const eq = makeBinary(makeTypedIdentResolved(matchSym, discType, loc), "===", bucket.tests[ti], loc);
				const setArm = makeExprStmt(makeAssign(makeIdentResolved(armSym, loc), makeNumber(bucket.arms[ti], loc), loc), loc);
				chain = makeIf(eq, makeBlock([setArm], loc), chain, loc);
			}
			hashCases.push(makeSwitchCase([makeNumber(bucket.hash, loc)], [chain], false, loc));
		}
		stmts.push(makeSwitch(makeCall(runtimeRef("msStringHash", loc), [discNode], loc), hashCases, loc));
		stmts.push(makeSwitch(makeIdentResolved(armSym, loc), dispatchCases, loc));
	}
	if (!defaultInSwitch && !isEmptyBlock(defaultBody)) {
		stmts.push(defaultBody);
	}
	return makeBlock(stmts, loc);
}

// ===== Tests =====
test "match stmt becomes if chain" { assert stmtCountAfter("match (x) { 1 => foo(), _ => bar() }", lowerMatch) == 2; }

test "match first stmt is VarDecl (discriminant temp)" { assert firstStmtKindAfter("match (x) { 1 => a(), _ => b() }", lowerMatch) == NodeKind.VariableDecl; }

test "no match passthrough" { assert stmtCountAfter("const x = 1;", lowerMatch) == 1; }

test "match preserves surrounding stmts" { assert stmtCountAfter("let a = 1; match (x) { _ => b() } let c = 2;", lowerMatch) == 4; }

test "string hash dispatch for >8 arms" {
	const src = "match (x) { \"a\" => 1, \"b\" => 2, \"c\" => 3, \"d\" => 4, \"e\" => 5, \"f\" => 6, \"g\" => 7, \"h\" => 8, \"i\" => 9, _ => 0 }";
	assert stmtCountAfter(src, lowerMatch) == 2;
}

test "few string arms stay as if-else" {
	const src = "match (x) { \"a\" => 1, \"b\" => 2, _ => 0 }";
	assert stmtCountAfter(src, lowerMatch) == 2;
}

function loweredMatchKind(src: string): NodeKind {
	const parsed = parseInput(src);
	if (!parsed.ok) return NodeKind.Program;
	return getStmts(lowerMatch(parsed.value, makeCtx()))[1].kind;
}

test "string hash dispatch counts labels, not arms" {
	assert loweredMatchKind("match (x) { \"a\" | \"b\" | \"c\" => 1, \"d\" | \"e\" | \"f\" => 2, \"g\" | \"h\" | \"i\" => 3, _ => 0 }") == NodeKind.BlockStmt;
	assert loweredMatchKind("match (x) { \"a\" | \"b\" | \"c\" | \"d\" => 1, \"e\" | \"f\" | \"g\" | \"h\" => 2, _ => 0 }") == NodeKind.IfStmt;
}

test "hash switch stmt mode lowers into one block" {
	const src = "match (cmd) { \"a\" => foo(), \"b\" => bar(), \"c\" => c(), \"d\" => d(), \"e\" => e(), \"f\" => f(), \"g\" => g(), \"h\" => h(), \"i\" => i(), _ => fallback() }";
	const stmts = stmtCountAfter(src, lowerMatch);
	assert stmts == 2;
}

test "djb2 hash deterministic" {
	assert hashStringSigned("hello") == hashStringSigned("hello");
	assert hashStringSigned("a") != hashStringSigned("b");
}
