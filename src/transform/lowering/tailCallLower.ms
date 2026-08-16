// Tail Call Lowering — transforms tail-recursive functions into while loops.
//
// function factorial(n, acc) {
//     if (n <= 1) return acc;
//     return factorial(n - 1, n * acc);
// }
// →
// function factorial(n, acc) {
//     let $tcp_0 = n;
//     let $tcp_1 = acc;
//     while (true) {
//         if ($tcp_0 <= 1) return $tcp_1;
//         const $tc_0 = $tcp_0 - 1;
//         const $tc_1 = $tcp_0 * $tcp_1;
//         $tcp_0 = $tc_0;
//         $tcp_1 = $tc_1;
//         continue;
//     }
// }
//
// Loop state lives in owned shadow locals, never in the param slots: the DRC
// analyzer models params as borrowed (never destroyed), so assigning owned
// values into them leaks. Params without a resolvable Symbol fall back to
// direct name assignment (pre-checker ASTs in unit tests).

import {
	Node, NodeKind, DeclKind, TypeKind, TypeFlag, SourceLocation, Symbol, SymbolKind,
	FunctionDeclData, ReturnStmtData, CallExprData, ConditionalExprData,
	IdentifierData, BlockStmtData, IfStmtData, BinaryExprData,
	ClassDeclData, MethodDeclData, MemberExprData,
	WhileStmtData, ContinueStmtData,
} from "../../ast/node";
import { TransformContext, freshTempSym, freshOwnedSym } from "../context";
import { noneType, peelToStruct } from "../../checker/types";
import { walkNode, mapChildren, isFuncBoundary } from "../walker";
import { forEachChild } from "../../ast/visitor";
import {
	makeBool, makeBlock, makeWhile, makeVarDecl, makeIf, makeReturn,
	makeIdent, makeIdentResolved, makeAssign, makeExprStmt, makeContinue,
	extractBodyStmts,
} from "../util";
import { lowerTernaryInReturn } from "./conditionalExprLower";
import { firstStmtKindAfter, stmtCountAfter } from "../testUtil";

const tcLoopLabel = "__tcl";

// ===== Main Entry Point =====

export function lowerTailCall(program: Node, ctx: TransformContext): Node {
	walkNode(program, tailCallVisitor(ctx));
	return program;
}

function tailCallVisitor(ctx: TransformContext): (node: Node) => Node {
	return (node: Node): Node => {
		if (node.kind === NodeKind.ClassDecl) return lowerClassMethods(node, ctx);
		if (node.kind !== NodeKind.FunctionDecl) return node;
		const d = node.data as FunctionDeclData;
		if (d.fnName === "") return node;
		d.fnBody = lowerSelfTailCalls(d.fnBody, d.fnName, node.resolvedSym, d.params, node.location, ctx);
		return node;
	};
}

// A method reached through `this` is only a static call when no subclass can
// replace it: Nim reads tfFinal for exactly this class of question
// (ccgexprs.nim:1995, types.nim:456). An extended class carries OpenClass; a
// class whose type cannot be resolved stays untouched.
function lowerClassMethods(node: Node, ctx: TransformContext): Node {
	const classStruct = peelToStruct(node.nodeType);
	if (classStruct === null) return node;
	if ((classStruct.typeFlags & TypeFlag.OpenClass) !== 0) return node;
	const cd = node.data as ClassDeclData;
	for (const member of cd.classBody) {
		if (member.kind !== NodeKind.MethodDecl) continue;
		const md = member.data as MethodDeclData;
		if (md.methodIsStatic) continue;
		// The receiver is the same object on every iteration, so it carries no loop
		// state; dropping it also keeps arguments aligned with parameters.
		const params: string[] = [];
		let first = md.methodParams.length > 0 && md.methodParams[0] === "this" ? 1 : 0;
		while (first < md.methodParams.length) {
			params.push(md.methodParams[first]);
			first += 1;
		}
		md.methodBody = lowerSelfTailCalls(md.methodBody, md.methodName, member.resolvedSym, params, member.location, ctx);
	}
	return node;
}

function lowerSelfTailCalls(body: Node, name: string, sym: Symbol | null, params: string[], loc: SourceLocation, ctx: TransformContext): Node {
	const statementized = statementizeTailPositions(body, name, sym, ctx);
	if (!hasTailCall(statementized, name, sym)) return statementized;

	const paramSyms = collectParamSyms(statementized, params);
	const localSyms: (Symbol | null)[] = [];
	const shadowDecls: Node[] = [];
	for (let i = 0; i < params.length; i += 1) {
		const ps = paramSyms[i];
		if (ps === null) {
			localSyms.push(null);
			continue;
		}
		const ls = freshOwnedSym(ctx, "tcp", ps.symbolType);
		const decl = makeVarDecl(ls.name, makeIdentResolved(ps, loc), DeclKind.Let, loc);
		decl.resolvedSym = ls;
		shadowDecls.push(decl);
		localSyms.push(ls);
	}
	rewriteParamRefs(statementized, paramSyms, localSyms);

	// Transform: wrap body in while(true), replace tail calls with reassign+continue
	const bodyStmts = extractBodyStmts(statementized);
	const newStmts: Node[] = [];
	for (let i = 0; i < bodyStmts.length; i += 1) {
		newStmts.push(transformStmt(bodyStmts[i], name, sym, params, localSyms, ctx));
	}

	const whileBody = makeBlock(newStmts, loc);
	const whileNode = makeWhile(makeBool(true, loc), whileBody, loc);
	(whileNode.data as WhileStmtData).whileLabel = tcLoopLabel;
	const outerStmts: Node[] = [];
	for (const sd of shadowDecls) {
		outerStmts.push(sd);
	}
	outerStmts.push(whileNode);
	return makeBlock(outerStmts, loc);
}

// Find the Symbol for each param name from references in the function's own
// scope (stops at nested function boundaries — same-name params of nested
// functions must not be picked up).
function collectParamSyms(body: Node, params: string[]): (Symbol | null)[] {
	const result: (Symbol | null)[] = [];
	for (const _p of params) {
		result.push(null);
	}
	collectInScope(body, params, result);
	return result;
}

function collectInScope(n: Node, params: string[], result: (Symbol | null)[]): void {
	if (n === null) return;
	const k = n.kind;
	if (k === NodeKind.FunctionDecl || k === NodeKind.FunctionExpr
		|| k === NodeKind.ArrowFunction || k === NodeKind.MethodDecl) return;
	if (k === NodeKind.Identifier && n.resolvedSym !== null
		&& n.resolvedSym.symbolKind === SymbolKind.Parameter) {
		const id = n.data as IdentifierData;
		for (let i = 0; i < params.length; i += 1) {
			if (params[i] === id.name && result[i] === null) {
				result[i] = n.resolvedSym;
			}
		}
	}
	mapChildren(n, (c: Node): Node => {
		collectInScope(c, params, result);
		return c;
	});
}

// Redirect every reference to a shadowed param (closures included — symbol
// identity makes this safe) to its loop-carried local.
function rewriteParamRefs(body: Node, fromSyms: (Symbol | null)[], toSyms: (Symbol | null)[]): void {
	walkNode(body, (n: Node): Node => {
		if (n.kind !== NodeKind.Identifier) return n;
		if (n.resolvedSym === null) return n;
		for (let i = 0; i < fromSyms.length; i += 1) {
			if (fromSyms[i] !== null && n.resolvedSym === fromSyms[i] && toSyms[i] !== null) {
				const id = n.data as IdentifierData;
				id.name = toSyms[i].name;
				n.resolvedSym = toSyms[i];
			}
		}
		return n;
	});
}

// A tail call is replaced by `continue`, a statement — so any tail position still
// held in an expression has to be expanded into statement form first. Mirrors
// lowerTernaryInReturn (conditionalExprLower), which runs too late for this pass
// and not at all on the JS backend.
function statementizeTailPositions(stmt: Node, fnName: string, fnSym: Symbol | null, ctx: TransformContext): Node {
	return match (stmt.kind) {
		NodeKind.BlockStmt => {
			const bd = stmt.data as BlockStmtData;
			for (let i = 0; i < bd.statements.length; i += 1) {
				bd.statements[i] = statementizeTailPositions(bd.statements[i], fnName, fnSym, ctx);
			}
			return stmt;
		},
		NodeKind.IfStmt => {
			const id = stmt.data as IfStmtData;
			id.consequent = statementizeTailPositions(id.consequent, fnName, fnSym, ctx);
			if (id.alternate !== null) {
				id.alternate = statementizeTailPositions(id.alternate, fnName, fnSym, ctx);
			}
			return stmt;
		},
		NodeKind.ReturnStmt => {
			const rd = stmt.data as ReturnStmtData;
			if (rd.argument === null) return stmt;
			if (rd.argument.kind === NodeKind.ConditionalExpr) {
				if (!ternaryHoldsTailCall(rd.argument, fnName, fnSym)) return stmt;
				const expanded = makeBlock(lowerTernaryInReturn(stmt, ctx), stmt.location);
				return statementizeTailPositions(expanded, fnName, fnSym, ctx);
			}
			if (rd.argument.kind === NodeKind.BinaryExpr) {
				const bd = rd.argument.data as BinaryExprData;
				if (bd.operator !== "&&" && bd.operator !== "||") return stmt;
				if (!ternaryHoldsTailCall(bd.right, fnName, fnSym)) return stmt;
				const loc = stmt.location;
				const lhsSym = freshTempSym(ctx, "sclhs", bd.left.nodeType);
				const lhsDecl = makeVarDecl(lhsSym.name, bd.left, DeclKind.Const, loc);
				lhsDecl.resolvedSym = lhsSym;
				const keepBlk = makeBlock([makeReturn(makeIdentResolved(lhsSym, loc), loc)], loc);
				const callBlk = makeBlock([tailArmStmt(bd.right, loc)], loc);
				const isAnd = bd.operator === "&&";
				const guard = makeIf(makeIdentResolved(lhsSym, loc), isAnd ? callBlk : keepBlk, isAnd ? keepBlk : callBlk, loc);
				return makeBlock([lhsDecl, statementizeTailPositions(guard, fnName, fnSym, ctx)], loc);
			}
			return stmt;
		},
		_ => stmt,
	};
}

function tailArmStmt(arm: Node, loc: SourceLocation): Node {
	if (arm.nodeType !== null && arm.nodeType.kind === TypeKind.Never) {
		return makeExprStmt(arm, loc);
	}
	return makeReturn(arm, loc);
}

function ternaryHoldsTailCall(expr: Node, fnName: string, fnSym: Symbol | null): boolean {
	if (expr === null) return false;
	if (expr.kind !== NodeKind.ConditionalExpr) return isTailCallExpr(expr, fnName, fnSym);
	const cd = expr.data as ConditionalExprData;
	if (ternaryHoldsTailCall(cd.ternaryConsequent, fnName, fnSym)) return true;
	return ternaryHoldsTailCall(cd.ternaryAlternate, fnName, fnSym);
}

// Check if a function body contains any tail calls (return f(args) where f === name)
function hasTailCall(body: Node, fnName: string, fnSym: Symbol | null): boolean {
	if (body.kind === NodeKind.ReturnStmt) {
		const rd = body.data as ReturnStmtData;
		return isTailCallExpr(rd.argument, fnName, fnSym);
	}
	if (tailOpaque(body)) return false;
	let found = false;
	forEachChild(body, (c: Node): void => {
		if (!found && hasTailCall(c, fnName, fnSym)) found = true;
	});
	return found;
}

// Check if an expression is a call to fnName. Symbol identity when both sides
// carry one (rules out shadowing and overload sets); name match as fallback.
function isTailCallExpr(expr: Node, fnName: string, fnSym: Symbol | null): boolean {
	if (expr === null) return false;
	if (expr.kind !== NodeKind.CallExpr) return false;
	const cd = expr.data as CallExprData;
	if (cd.callee.kind === NodeKind.MemberExpr) return isThisMethodCall(cd.callee, fnName, fnSym);
	if (cd.callee.kind !== NodeKind.Identifier) return false;
	if (fnSym !== null && cd.callee.resolvedSym !== null) {
		return cd.callee.resolvedSym === fnSym;
	}
	const id = cd.callee.data as IdentifierData;
	return id.name === fnName;
}

function isThisMethodCall(callee: Node, fnName: string, fnSym: Symbol | null): boolean {
	const md = callee.data as MemberExprData;
	if (md.property !== fnName) return false;
	if (md.object.kind !== NodeKind.Identifier) return false;
	if ((md.object.data as IdentifierData).name !== "this") return false;
	if (fnSym !== null && callee.resolvedSym !== null) return callee.resolvedSym === fnSym;
	return true;
}

function tailOpaque(stmt: Node): boolean {
	return stmt.kind === NodeKind.TryCatchStmt ||
		stmt.kind === NodeKind.DeferStmt ||
		isFuncBoundary(stmt);
}

function transformStmt(stmt: Node, fnName: string, fnSym: Symbol | null, params: string[], localSyms: (Symbol | null)[], ctx: TransformContext): Node {
	return match (stmt.kind) {
		NodeKind.ReturnStmt => {
			const rd = stmt.data as ReturnStmtData;
			if (isTailCallExpr(rd.argument, fnName, fnSym)) {
				return buildTailCallReplacement(rd.argument, params, localSyms, stmt.location, ctx);
			}
			return stmt;
		},
		_ => {
			if (tailOpaque(stmt)) return stmt;
			mapChildren(stmt, (c: Node): Node => transformStmt(c, fnName, fnSym, params, localSyms, ctx));
			return stmt;
		},
	};
}

// Transform a block body (recurse into statements)
function transformBody(body: Node, fnName: string, fnSym: Symbol | null, params: string[], localSyms: (Symbol | null)[], ctx: TransformContext): Node {
	return match (body.kind) {
		NodeKind.BlockStmt => {
			const bd = body.data as BlockStmtData;
			let i = 0;
			while (i < bd.statements.length) {
				bd.statements[i] = transformStmt(bd.statements[i], fnName, fnSym, params, localSyms, ctx);
				i += 1;
			}
			return body;
		},
		_ => transformStmt(body, fnName, fnSym, params, localSyms, ctx),
	};
}

// Build replacement for tail call: temp vars for args, reassign loop locals, continue
function buildTailCallReplacement(callExpr: Node, params: string[], localSyms: (Symbol | null)[], loc: SourceLocation, ctx: TransformContext): Node {
	const cd = callExpr.data as CallExprData;
	const stmts: Node[] = [];

	// 1. Evaluate all arguments into temps (avoid order-of-evaluation issues)
	const tempSyms: Symbol[] = [];
	for (let i = 0; i < cd.arguments.length && i < params.length; i += 1) {
		const argType = cd.arguments[i].nodeType !== null ? cd.arguments[i].nodeType : noneType();
		const sym = freshTempSym(ctx, "tc", argType);
		tempSyms.push(sym);
		const tcDecl = makeVarDecl(sym.name, cd.arguments[i], DeclKind.Const, loc);
		tcDecl.resolvedSym = sym;
		stmts.push(tcDecl);
	}

	// 2. Reassign loop-carried locals from temps
	for (let j = 0; j < tempSyms.length; j += 1) {
		const ls = localSyms[j];
		const target = ls !== null ? makeIdentResolved(ls, loc) : makeIdent(params[j], loc);
		const assignExpr = makeAssign(target, makeIdentResolved(tempSyms[j], loc), loc);
		stmts.push(makeExprStmt(assignExpr, loc));
	}

	// 3. Continue (back to top of while loop)
	const cont = makeContinue(loc);
	(cont.data as ContinueStmtData).continueLabel = tcLoopLabel;
	stmts.push(cont);

	return makeBlock(stmts, loc);
}

// ===== Tests =====
test "non-recursive unchanged" { assert firstStmtKindAfter("function foo(x: number): number { return x + 1; }", lowerTailCall) === NodeKind.FunctionDecl; }

test "simple passthrough" { assert stmtCountAfter("const x = 1;", lowerTailCall) === 1; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerTailCall) === NodeKind.WhileStmt; }

test "if stmt unchanged" { assert firstStmtKindAfter("if (x) {}", lowerTailCall) === NodeKind.IfStmt; }

test "non-function passthrough" { assert stmtCountAfter("let a = 1; let b = 2;", lowerTailCall) === 2; }

test "arrow function unchanged" { assert firstStmtKindAfter("const f = (x: number): number => x + 1;", lowerTailCall) === NodeKind.VariableDecl; }
