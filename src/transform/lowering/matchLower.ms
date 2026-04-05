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

import { Node, NodeKind, DeclKind, TypeKind, SourceLocation, BlockStmtData, MatchStmtData, MatchExprData, MatchCaseData, VariableDeclData, ReturnStmtData, ExprStmtData, IfStmtData, IdentifierData, NumberLiteralData, StringLiteralData, Type, isEmptyBlock } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { walkExpandBlocks, containsExprKind, replaceInExpr } from "../walker";
import {
	makeIdent, makeIdentResolved, makeTypedIdent, makeBlock, makeVarDecl, makeExprStmt, makeNull,
	makeReturn, makeIf, makeBinary, makeAssign, makeBool, makeUnary,
	makeCall, makeNumber, makeSwitch, makeSwitchCase,
} from "../util";
import { unknownType } from "../../checker/types";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";
import { hashStringSigned } from "std/hash";

// ===== Nested MatchExpr Hoisting via shared walker =====
// Uses replaceInExpr from walker.ms — same expression tree walker as resultDesugar.

function hoistNestedMatch(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	return replaceInExpr(expr, (node: Node): Node => {
		if (node.kind !== NodeKind.MatchExpr) return node;
		const matchData = node.data as MatchExprData;
		const loc = node.location;
		const matchSym = freshTempSym(ctx, "match", matchData.matchDisc.nodeType);
		const resultSym = freshTempSym(ctx, "matchres", node.nodeType);

		// const $match_N = discriminant;
		const matchDecl = makeVarDecl(matchSym.name, matchData.matchDisc, DeclKind.Const, loc);
		matchDecl.resolvedSym = matchSym;
		hoisted.push(matchDecl);
		const discType = matchData.matchDisc.nodeType;

		// let $matchres_N;
		const placeholder = makeNull(loc);
		const letDecl = makeVarDecl(resultSym.name, placeholder, DeclKind.Let, loc);
		letDecl.resolvedSym = resultSym;
		if (node.nodeType !== null) { letDecl.nodeType = node.nodeType; }
		hoisted.push(letDecl);

		// if-chain assigning to $matchres_N
		hoisted.push(buildIfChain(matchData.matchCases, matchSym.name, discType, loc, "assign", resultSym.name, ctx));

		// Replace MatchExpr with $matchres_N
		return makeIdentResolved(resultSym, loc);
	});
}

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
			if (d.initializer !== null && d.initializer.kind === NodeKind.MatchExpr) {
				return lowerMatchExprInVar(stmt, ctx);
			}
			if (d.initializer !== null && containsExprKind(d.initializer, NodeKind.MatchExpr)) {
				const hoisted: Node[] = [];
				d.initializer = hoistNestedMatch(d.initializer, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			if (d.argument !== null && d.argument.kind === NodeKind.MatchExpr) {
				return lowerMatchExprInReturn(stmt, ctx);
			}
			if (d.argument !== null && containsExprKind(d.argument, NodeKind.MatchExpr)) {
				const hoisted: Node[] = [];
				d.argument = hoistNestedMatch(d.argument, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr.kind === NodeKind.MatchStmt) {
				return lowerMatchStmt(d.expr, ctx);
			}
			if (d.expr.kind === NodeKind.MatchExpr) {
				return lowerMatchExprAsStmt(d.expr, ctx);
			}
			if (containsExprKind(d.expr, NodeKind.MatchExpr)) {
				const hoisted: Node[] = [];
				d.expr = hoistNestedMatch(d.expr, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
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
	const matchSym = freshTempSym(ctx, "match", d.matchStmtDisc.nodeType);
	const tempName = matchSym.name;
	const result: Node[] = [];

	// const $match_N = discriminant;
	const matchDecl = makeVarDecl(tempName, d.matchStmtDisc, DeclKind.Const, loc);
	matchDecl.resolvedSym = matchSym;
	result.push(matchDecl);
	const discType = d.matchStmtDisc.nodeType;

	// Build if-else chain from cases
	const ifChain = buildIfChain(d.matchStmtCases, tempName, discType, loc, "stmt", "", ctx);
	result.push(ifChain);

	return result;
}

// ===== MatchExpr at statement position (value discarded) =====

function lowerMatchExprAsStmt(matchNode: Node, ctx: TransformContext): Node[] {
	const d = matchNode.data as MatchExprData;
	const loc = matchNode.location;
	const matchSym = freshTempSym(ctx, "match", d.matchDisc.nodeType);
	const tempName = matchSym.name;
	const result: Node[] = [];
	const matchDecl = makeVarDecl(tempName, d.matchDisc, DeclKind.Const, loc);
	matchDecl.resolvedSym = matchSym;
	result.push(matchDecl);
	const discType = d.matchDisc.nodeType;
	const ifChain = buildIfChain(d.matchCases, tempName, discType, loc, "stmt", "", ctx);
	result.push(ifChain);
	return result;
}

// ===== MatchExpr in VariableDecl → let x; if-chain with x = armValue =====

function lowerMatchExprInVar(stmt: Node, ctx: TransformContext): Node[] {
	const varData = stmt.data as VariableDeclData;
	const matchData = varData.initializer.data as MatchExprData;
	const loc = stmt.location;
	const matchSym = freshTempSym(ctx, "match", matchData.matchDisc.nodeType);
	const tempName = matchSym.name;
	const result: Node[] = [];

	// const $match_N = discriminant;
	const matchDecl = makeVarDecl(tempName, matchData.matchDisc, DeclKind.Const, loc);
	matchDecl.resolvedSym = matchSym;
	result.push(matchDecl);
	const discType = matchData.matchDisc.nodeType;
	// let x; (uninitialized, to be assigned in each branch)
	const placeholder = makeNull(loc);
	const letDecl = makeVarDecl(varData.declName, placeholder, DeclKind.Let, loc);
	if (stmt.nodeType !== null) {
		letDecl.nodeType = stmt.nodeType;
	}
	result.push(letDecl);
	// if-chain with assignment: x = armValue
	const ifChain = buildIfChain(matchData.matchCases, tempName, discType, loc, "assign", varData.declName, ctx);
	result.push(ifChain);

	return result;
}

// ===== MatchExpr in ReturnStmt → if-chain with return armValue =====

function lowerMatchExprInReturn(stmt: Node, ctx: TransformContext): Node[] {
	const retData = stmt.data as ReturnStmtData;
	const matchData = retData.argument.data as MatchExprData;
	const loc = stmt.location;
	const matchSym = freshTempSym(ctx, "match", matchData.matchDisc.nodeType);
	const tempName = matchSym.name;
	const result: Node[] = [];

	// const $match_N = discriminant;
	const matchDecl = makeVarDecl(tempName, matchData.matchDisc, DeclKind.Const, loc);
	matchDecl.resolvedSym = matchSym;
	result.push(matchDecl);
	const discType = matchData.matchDisc.nodeType;
	// if-chain with return: return armValue
	const ifChain = buildIfChain(matchData.matchCases, tempName, discType, loc, "return", "", ctx);
	result.push(ifChain);

	return result;
}

// ===== Build if-else chain =====
// Unified builder for all match contexts.
// mode: "stmt" = body as-is, "assign" = varName = body, "return" = return body

// Check if all non-wildcard/non-binding patterns are enum members or integer literals.
// Guards are allowed — they become if-chains inside switch case bodies.
function canUseSwitchDispatch(cases: Node[], discType: Type): boolean {
	if (discType === null) return false;
	// Only integer types and enums — C switch requires integer discriminant.
	// TypeKind.Number is double in C, NOT valid for switch.
	const k = discType.kind;
	if (k !== TypeKind.Enum && k !== TypeKind.Int8
		&& k !== TypeKind.Int16 && k !== TypeKind.Int32 && k !== TypeKind.Int64
		&& k !== TypeKind.Uint8 && k !== TypeKind.Uint16 && k !== TypeKind.Uint32
		&& k !== TypeKind.Uint64) {
		return false;
	}
	for (let i = 0; i < cases.length; i += 1) {
		const cd = cases[i].data as MatchCaseData;
		if (isWildcard(cd.casePatterns)) continue;
		if (isBindingPattern(cd.casePatterns)) return false;
		for (let j = 0; j < cd.casePatterns.length; j += 1) {
			const p = cd.casePatterns[j];
			if (p.kind === NodeKind.NumberLiteral) continue;
			if (p.kind === NodeKind.Identifier && p.resolvedSym !== null) continue;
			if (p.kind === NodeKind.MemberExpr) {
				// Only accept enum member access (Color.Red), not .code or other property access.
				// .code patterns are MemberExpr but resolve to runtime values, not constants.
				const pmd = p.data as { object: Node, property: string };
				if (pmd.object !== null && pmd.object.nodeType !== null && pmd.object.nodeType.kind === TypeKind.Enum) continue;
				return false;
			}
			if (p.kind === NodeKind.UnaryExpr) continue;
			return false;
		}
	}
	return true;
}

// Build switch dispatch for enum/int patterns with guard support.
// Groups same-pattern arms with different guards into one switch case.
function buildSwitchDispatch(cases: Node[], tempName: string, discType: Type, loc: SourceLocation, mode: string, varName: string, ctx: TransformContext): Node {
	// Build default body from wildcards: process unguarded first (base), then guarded (wrap).
	// This ensures: _ when g1 => b1, _ when g2 => b2, _ => b3
	// becomes: if (g1) { b1 } else if (g2) { b2 } else { b3 }
	let defaultBody = makeBlock([], loc);
	for (let wi = cases.length - 1; wi >= 0; wi -= 1) {
		const wd = cases[wi].data as MatchCaseData;
		if (!isWildcard(wd.casePatterns)) continue;
		const body = wrapArmBody(wd.caseBody, mode, varName, loc);
		if (wd.caseGuard !== null) {
			defaultBody = makeIf(wd.caseGuard, body, defaultBody, loc);
		} else {
			defaultBody = body;
		}
	}

	// The $matched flag is ONLY needed when (a) arms can't early-return (stmt/assign
	// mode) AND (b) the default body is observably non-empty. No wildcard, or
	// `_ => {}`, means there's nothing to gate — skip the flag entirely to eliminate
	// dead stores and empty `if (!$matched) {}` epilogues in the generated C.
	const needsFlag = mode !== "return" && !isEmptyBlock(defaultBody);
	const matchedSym = freshTempSym(ctx, "matched", unknownType());
	const matchedName = matchedSym.name;

	// Reference-aligned lowering: each MatchCase maps to ONE SwitchCase holding
	// all of its OR-patterns (A | B | C) as caseTests. The C backend emits this
	// as `case A: case B: case C: { body } break;` — one body with multiple
	// fall-through labels, matching standard multi-label branch semantics.
	//
	// Cross-MatchCase merging: two MatchCases with the IDENTICAL pattern set
	// (same labels, possibly in different order) merge into one SwitchCase with
	// an if-else guard chain. This handles both:
	//   (a) Single-pattern guard chain — `case 1 when g1 => a; case 1 => b`
	//   (b) OR-pattern guard chain    — `case A|B when g => x; case A|B => y`
	// Both collapse into one SwitchCase with chained bodies inside caseStmts.
	//
	// Partial overlap (`case A|B => x; case A when g => y`) is rejected via
	// labelOwners bookkeeping — merging would run the second arm's body on
	// sibling labels it wasn't meant to match, and emitting separate SwitchCases
	// would produce duplicate C `case` labels. Reference compilers catch this
	// at sem time as "duplicate case label"; we catch it here and push a clear
	// error into ctx.errors.
	const patternKeys: string[] = [];    // canonical set-signature per group
	const patternTests: Node[][] = [];   // caseTests arrays per group
	const armGuards: Node[][] = [];
	const armBodies: Node[][] = [];
	// Per-label index for partial-overlap detection.
	const labelOwners: string[] = [];
	const labelOwnerGroup: number[] = [];

	for (let i = 0; i < cases.length; i += 1) {
		const caseData = cases[i].data as MatchCaseData;
		if (isWildcard(caseData.casePatterns)) continue;

		const setKey = patternSetKey(caseData.casePatterns, i);

		// Same-set merge (handles both single-pattern and OR-pattern guard chains).
		let mergedInto = -1;
		for (let gi = 0; gi < patternKeys.length; gi += 1) {
			if (patternKeys[gi] === setKey) {
				mergedInto = gi;
				break;
			}
		}

		// Partial-overlap detection for new groups: any individual label that
		// already belongs to a different group means duplicate C case labels.
		if (mergedInto < 0) {
			for (const pat of caseData.casePatterns) {
				const lk = patternKey(pat, i);
				let owner = -1;
				for (let li = 0; li < labelOwners.length; li += 1) {
					if (labelOwners[li] === lk) { owner = labelOwnerGroup[li]; break; }
				}
				if (owner >= 0) {
					ctx.errors.push("match: duplicate case label '" + lk + "' — pattern overlaps a previous arm with a different pattern set; use either identical or non-overlapping arms");
				}
			}
		}

		const armBody = wrapArmBody(caseData.caseBody, mode, varName, loc);

		if (mergedInto >= 0) {
			armGuards[mergedInto].push(caseData.caseGuard);
			armBodies[mergedInto].push(armBody);
		} else {
			const newGroupIdx = patternKeys.length;
			patternKeys.push(setKey);
			patternTests.push(caseData.casePatterns);
			armGuards.push([caseData.caseGuard]);
			armBodies.push([armBody]);
			for (const pat of caseData.casePatterns) {
				labelOwners.push(patternKey(pat, i));
				labelOwnerGroup.push(newGroupIdx);
			}
		}
	}

	// Build switch cases from grouped arms
	const switchCases: Node[] = [];
	for (let gi = 0; gi < patternKeys.length; gi += 1) {
		const guards = armGuards[gi];
		const bodies = armBodies[gi];
		const caseStmts: Node[] = [];

		// Chain guard-body pairs as if-else: if (g1) { body1 } if (g2) { body2 } body_unguarded
		for (let ai = 0; ai < guards.length; ai += 1) {
			let armBody = bodies[ai];
			if (needsFlag) {
				const setMatched = makeExprStmt(makeAssign(makeIdentResolved(matchedSym, loc), makeBool(true, loc), loc), loc);
				armBody = makeBlock([setMatched, armBody], loc);
			}
			if (guards[ai] !== null) {
				caseStmts.push(makeIf(guards[ai], armBody, makeBlock([], loc), loc));
			} else {
				caseStmts.push(armBody);
			}
		}

		switchCases.push(makeSwitchCase(patternTests[gi], caseStmts, false, loc));
	}

	// Build final switch
	const discIdent = makeTypedIdent(tempName, discType, loc);
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

function buildIfChain(cases: Node[], tempName: string, discType: Type, loc: SourceLocation, mode: string, varName: string, ctx: TransformContext): Node {
	// String hash dispatch for >8 string cases
	if (isAllStringCases(cases)) {
		return buildHashSwitch(cases, tempName, discType, loc, mode, varName, ctx);
	}

	// Switch dispatch for enum/int discriminants (O(1) jump table in C)
	if (canUseSwitchDispatch(cases, discType)) {
		return buildSwitchDispatch(cases, tempName, discType, loc, mode, varName, ctx);
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
			if (caseData.caseGuard !== null) {
				// Guarded wildcard: if (guard) { body } else { previous_else }
				elseNode = makeIf(caseData.caseGuard, body, elseNode, loc);
			} else {
				elseNode = body;
			}
			continue;
		}

		if (isBindingPattern(caseData.casePatterns)) {
			const bindingName = getBindingName(caseData.casePatterns);
			const bindDecl = makeVarDecl(bindingName, makeTypedIdent(tempName, discType, loc), DeclKind.Const, loc);
			if (caseData.caseGuard !== null) {
				// Bind first, then check guard
				const guardedBody = makeIf(caseData.caseGuard, body, elseNode, loc);
				elseNode = prependToBody(bindDecl, guardedBody, loc);
			} else {
				elseNode = prependToBody(bindDecl, body, loc);
			}
			continue;
		}

		// No wildcard and this is the last arm → use as unconditional else
		// (checker verified exhaustiveness, so this is safe)
		if (!hasDefault && i === cases.length - 1 && caseData.caseGuard === null) {
			elseNode = body;
			continue;
		}

		let cond = buildPatternCondition(caseData.casePatterns, tempName, discType, loc);
		if (caseData.caseGuard !== null) {
			cond = makeBinary(cond, "&&", caseData.caseGuard, loc);
		}
		elseNode = makeIf(cond, body, elseNode, loc);
	}

	return elseNode;
}

// ===== moveInto — Unified Result Destination Insertion =====
// Standard reference pattern: unified result destination insertion
// Pushes the "result destination" (return or assignment) into terminal positions.
// C has no expression-blocks — this makes each arm produce a statement-level result.

function wrapArmBody(armBody: Node, mode: string, varName: string, loc: SourceLocation): Node {
	if (mode === "stmt") {
		// Expression-form arms (=> expr) need wrapping in ExprStmt for codegen.
		// Block-form arms (=> { ... }) are already BlockStmt — pass through.
		if (armBody.kind !== NodeKind.BlockStmt && armBody.kind !== NodeKind.ExprStmt
			&& armBody.kind !== NodeKind.IfStmt && armBody.kind !== NodeKind.ReturnStmt
			&& armBody.kind !== NodeKind.BreakStmt && armBody.kind !== NodeKind.ContinueStmt
			&& armBody.kind !== NodeKind.ThrowStmt && armBody.kind !== NodeKind.VariableDecl) {
			return makeExprStmt(armBody, loc);
		}
		return armBody;
	}
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
	// Control flow terminals: BreakStmt/ContinueStmt keep as-is
	if (node.kind === NodeKind.BreakStmt || node.kind === NodeKind.ContinueStmt) {
		return node;
	}
	// ReturnStmt in "return" mode: keep as-is (already correct).
	// ReturnStmt in "assign" mode: strip return, convert to assignment.
	// This supports `const x = match { arm => { return expr; } }` syntax.
	if (node.kind === NodeKind.ReturnStmt) {
		if (mode === "return") return node;
		const rd = node.data as ReturnStmtData;
		if (rd.argument !== null) {
			return emitResult(rd.argument, mode, varName, loc);
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

// Semantic key for cross-MatchCase grouping. Two patterns with the same key
// refer to the same discriminant value (enum member, literal). Used by the
// guard-chain merge path in buildSwitchDispatch.
function patternKey(pat: Node, caseIdx: number): string {
	return match (pat.kind) {
		NodeKind.NumberLiteral => `n:${(pat.data as NumberLiteralData).value}`,
		NodeKind.Identifier => "id:" + (pat.data as IdentifierData).name,
		NodeKind.MemberExpr => {
			if (pat.resolvedSym !== null) return "sym:" + pat.resolvedSym.name;
			return "m:" + (pat.data as { object: Node, property: string }).property;
		},
		// Unique fallback — never matches another pattern, effectively disables merge.
		_ => `x:${caseIdx}`,
	};
}

// Canonical signature of a pattern set for same-set merging. Sorts label keys
// so that `A | B` and `B | A` collapse to the same group.
function patternSetKey(patterns: Node[], caseIdx: number): string {
	const keys: string[] = [];
	for (const pat of patterns) {
		keys.push(patternKey(pat, caseIdx));
	}
	// Insertion sort — pattern sets are tiny (typically 1-4 items).
	for (let i = 1; i < keys.length; i += 1) {
		const x = keys[i];
		let j = i - 1;
		while (j >= 0 && keys[j] > x) {
			keys[j + 1] = keys[j];
			j -= 1;
		}
		keys[j + 1] = x;
	}
	let sig = "";
	for (let k = 0; k < keys.length; k += 1) {
		if (k > 0) sig = sig + "|";
		sig = sig + keys[k];
	}
	return sig;
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
// Matches standard string-case optimization pattern.

const STRING_HASH_THRESHOLD: number = 8;

// DJB2 hash — uses hashStringSigned from std/hash (matches C runtime msStringHash).

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

// Hash bucket entry: a guarded if-body for one string pattern within a hash bucket.
interface HashBucket {
	hash: int32;
	guards: Node[];  // chained if-guards for patterns sharing this hash
}

// Build switch(djb2(disc)) { case HASH: if (eq1) { body } else if (eq2) { body } break; ... }
// Collision-safe: patterns sharing a hash are chained in the same case arm.
// Return mode: matched arms `return`, so default body placed unconditionally after switch.
// Stmt/assign mode: matched arms don't exit, so $matched flag guards the default body.
function buildHashSwitch(cases: Node[], tempName: string, discType: Type, loc: SourceLocation, mode: string, varName: string, ctx: TransformContext): Node {
	let defaultBody = makeBlock([], loc);
	// return mode: matched arms exit via return — no flag needed, unconditional default is safe.
	// stmt/assign mode: matched arms don't exit — need $matched flag to skip default.
	// Pre-scan wildcards: the flag is only meaningful when some wildcard arm has a
	// reachable, non-empty body (guarded or non-empty block). Without a real default
	// to gate, the flag becomes dead stores + an empty `if (!$matched)` epilogue.
	let hasRealDefault = false;
	for (const c of cases) {
		const pd = c.data as MatchCaseData;
		if (!isWildcard(pd.casePatterns)) continue;
		if (pd.caseGuard !== null || !isEmptyBlock(pd.caseBody)) {
			hasRealDefault = true;
			break;
		}
	}
	const needsFlag = mode !== "return" && hasRealDefault;
	const matchedSym = freshTempSym(ctx, "matched", unknownType());
	const matchedName = matchedSym.name;

	// Collect patterns into hash buckets — patterns with the same hash share a bucket.
	const buckets: HashBucket[] = [];

	for (let i = 0; i < cases.length; i += 1) {
		const caseData = cases[i].data as MatchCaseData;
		if (isWildcard(caseData.casePatterns)) {
			defaultBody = wrapArmBody(caseData.caseBody, mode, varName, loc);
			continue;
		}

		for (let j = 0; j < caseData.casePatterns.length; j += 1) {
			const pat = caseData.casePatterns[j];
			const strData = pat.data as StringLiteralData;
			const hash = hashStringSigned(strData.value);

			const body = wrapArmBody(caseData.caseBody, mode, varName, loc);
			let guardedBlock = body;
			if (needsFlag) {
				const setMatched = makeExprStmt(makeAssign(makeIdentResolved(matchedSym, loc), makeBool(true, loc), loc), loc);
				const guardedBodyStmts: Node[] = [];
				guardedBodyStmts.push(setMatched);
				guardedBodyStmts.push(body);
				guardedBlock = makeBlock(guardedBodyStmts, loc);
			}
			const guard = makeBinary(makeTypedIdent(tempName, discType, loc), "===", pat, loc);
			const guardedIf = makeIf(guard, guardedBlock, makeBlock([], loc), loc);

			// Find existing bucket or create new one
			let found = false;
			let bi = 0;
			while (bi < buckets.length) {
				if (buckets[bi].hash === hash) {
					buckets[bi].guards.push(guardedIf);
					found = true;
					break;
				}
				bi += 1;
			}
			if (!found) {
				const guards: Node[] = [];
				guards.push(guardedIf);
				buckets.push({ hash, guards });
			}
		}
	}

	// Build switch cases from buckets — one case per unique hash value
	const switchCases: Node[] = [];
	for (let bi = 0; bi < buckets.length; bi += 1) {
		const bucket = buckets[bi];
		const caseStmts: Node[] = [];
		// Chain all guards for this hash bucket (handles collisions)
		for (let gi = 0; gi < bucket.guards.length; gi += 1) {
			caseStmts.push(bucket.guards[gi]);
		}
		const hashNode = makeNumber(bucket.hash, loc);
		const tests: Node[] = [];
		tests.push(hashNode);
		switchCases.push(makeSwitchCase(tests, caseStmts, false, loc));
	}

	// switch (msStringHash(temp)) for C, switch (hashStringSigned(temp)) for JS
	const hashFn = ctx.jsBackend ? "hashStringSigned" : "msStringHash";
	const hashCallArgs: Node[] = [];
	hashCallArgs.push(makeTypedIdent(tempName, discType, loc));
	const hashCall = makeCall(makeIdent(hashFn, loc), hashCallArgs, loc);
	const switchNode = makeSwitch(hashCall, switchCases, loc);

	const stmts: Node[] = [];
	if (needsFlag) {
		// let $matched = false; switch(...) { ... } if (!$matched) { wildcard }
		const matchedDecl2 = makeVarDecl(matchedName, makeBool(false, loc), DeclKind.Let, loc);
		matchedDecl2.resolvedSym = matchedSym;
		stmts.push(matchedDecl2);
		stmts.push(switchNode);
		const notMatched = makeUnary("!", makeIdentResolved(matchedSym, loc), loc);
		stmts.push(makeIf(notMatched, defaultBody, makeBlock([], loc), loc));
	} else {
		// return mode: matched arms return, so default body is only reachable when
		// no case matched (or hash collision with guard failure). Unconditional placement
		// keeps C compiler happy (guaranteed return path).
		stmts.push(switchNode);
		if (!isEmptyBlock(defaultBody)) {
			stmts.push(defaultBody);
		}
	}
	return makeBlock(stmts, loc);
}

// ===== Tests =====
test "match stmt becomes if chain" { assert stmtCountAfter("match (x) { 1 => foo(), _ => bar() }", lowerMatch) === 2; }

test "match first stmt is VarDecl (discriminant temp)" { assert firstStmtKindAfter("match (x) { 1 => a(), _ => b() }", lowerMatch) === NodeKind.VariableDecl; }

test "no match passthrough" { assert stmtCountAfter("const x = 1;", lowerMatch) === 1; }

test "match preserves surrounding stmts" { assert stmtCountAfter("let a = 1; match (x) { _ => b() } let c = 2;", lowerMatch) === 4; }

test "string hash dispatch for >8 arms" {
	const src = "match (x) { \"a\" => 1, \"b\" => 2, \"c\" => 3, \"d\" => 4, \"e\" => 5, \"f\" => 6, \"g\" => 7, \"h\" => 8, \"i\" => 9, _ => 0 }";
	// 9 string arms > threshold(8) → should produce SwitchStmt (2nd stmt after VarDecl temp)
	assert stmtCountAfter(src, lowerMatch) === 2;
}

test "few string arms stay as if-else" {
	const src = "match (x) { \"a\" => 1, \"b\" => 2, _ => 0 }";
	// 2 string arms <= threshold → stays as if-else chain
	assert stmtCountAfter(src, lowerMatch) === 2;
}

test "hash switch stmt mode produces $matched guard" {
	// >8 string arms in stmt match → hash switch with $matched flag
	const src = "match (cmd) { \"a\" => foo(), \"b\" => bar(), \"c\" => c(), \"d\" => d(), \"e\" => e(), \"f\" => f(), \"g\" => g(), \"h\" => h(), \"i\" => i(), _ => fallback() }";
	const stmts = stmtCountAfter(src, lowerMatch);
	// Top level: [VarDecl($match_temp), BlockStmt(VarDecl($matched) + Switch + If)]
	assert stmts === 2;
}

test "djb2 hash deterministic" {
	assert hashStringSigned("hello") === hashStringSigned("hello");
	assert hashStringSigned("a") !== hashStringSigned("b");
}
