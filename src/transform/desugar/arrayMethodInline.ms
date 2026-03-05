// Array Method Inline — arr.map/filter/reduce → inline while loops
// Nim-aligned: mapIt/filterIt/foldl template expansion, zero call overhead
//
// Detection: CallExpr whose callee is MemberExpr with property "map"/"filter"/"reduce"
// and correct argument count (map/filter: 1, reduce: 2).
//
// Handles ReturnStmt and VariableDecl contexts:
//   return arr.map(fn);
//     → const $mArr = arr; const $mRes = []; let $mI = 0;
//       while ($mI < $mArr.length) { $mRes.push(fn($mArr[$mI], $mI)); $mI = $mI + 1; }
//       return $mRes;

import {
	Node, NodeKind, DeclKind, SourceLocation, createNode,
	ReturnStmtData, VariableDeclData, CallExprData, MemberExprData,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { walkExpandBlocks } from "../walker";
import {
	makeVarDecl, makeIdent, makeCall, makeMember, makeExprStmt, makeBlock,
	makeReturn, makeWhile, makeBinary, makeNumber, makeAssign, makeArrayAccess,
	makeIf, syntheticToken,
} from "../util";
import { check } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Detection =====

function getArrayMethodName(node: Node): string {
	if (node === null) return "";
	if (node.kind !== NodeKind.CallExpr) return "";
	const cd = node.data as CallExprData;
	if (cd.callee.kind !== NodeKind.MemberExpr) return "";
	const md = cd.callee.data as MemberExprData;
	if (md.property === "map" && cd.arguments.length === 1) return "map";
	if (md.property === "filter" && cd.arguments.length === 1) return "filter";
	if (md.property === "reduce" && cd.arguments.length === 2) return "reduce";
	return "";
}

// ===== Helpers =====

function makeEmptyArray(loc: SourceLocation): Node {
	return createNode(NodeKind.ArrayLiteral, { elements: [] }, syntheticToken(loc));
}

function makeIncrement(iName: string, loc: SourceLocation): Node {
	return makeExprStmt(makeAssign(
		makeIdent(iName, loc),
		makeBinary(makeIdent(iName, loc), "+", makeNumber(1, loc), loc),
	loc), loc);
}

function makeLengthCond(iName: string, arrName: string, loc: SourceLocation): Node {
	return makeBinary(makeIdent(iName, loc), "<", makeMember(makeIdent(arrName, loc), "length", loc), loc);
}

// ===== Loop Builders =====
// Each returns Node[] of the loop setup + while. Caller appends final return/varDecl.

function buildMap(arrExpr: Node, callbackExpr: Node, arrName: string, resName: string, iName: string, loc: SourceLocation): Node[] {
	const stmts: Node[] = [];
	stmts.push(makeVarDecl(arrName, arrExpr, DeclKind.Const, loc));
	stmts.push(makeVarDecl(resName, makeEmptyArray(loc), DeclKind.Const, loc));
	stmts.push(makeVarDecl(iName, makeNumber(0, loc), DeclKind.Let, loc));

	const bodyStmts: Node[] = [];
	const elem = makeArrayAccess(makeIdent(arrName, loc), makeIdent(iName, loc), loc);
	const callArgs: Node[] = [];
	callArgs.push(elem);
	callArgs.push(makeIdent(iName, loc));
	const pushArgs: Node[] = [];
	pushArgs.push(makeCall(callbackExpr, callArgs, loc));
	bodyStmts.push(makeExprStmt(makeCall(makeMember(makeIdent(resName, loc), "push", loc), pushArgs, loc), loc));
	bodyStmts.push(makeIncrement(iName, loc));

	stmts.push(makeWhile(makeLengthCond(iName, arrName, loc), makeBlock(bodyStmts, loc), loc));
	return stmts;
}

function buildFilter(arrExpr: Node, callbackExpr: Node, arrName: string, resName: string, iName: string, loc: SourceLocation): Node[] {
	const stmts: Node[] = [];
	stmts.push(makeVarDecl(arrName, arrExpr, DeclKind.Const, loc));
	stmts.push(makeVarDecl(resName, makeEmptyArray(loc), DeclKind.Const, loc));
	stmts.push(makeVarDecl(iName, makeNumber(0, loc), DeclKind.Let, loc));

	const bodyStmts: Node[] = [];
	const elem = makeArrayAccess(makeIdent(arrName, loc), makeIdent(iName, loc), loc);
	const filterArgs: Node[] = [];
	filterArgs.push(elem);
	filterArgs.push(makeIdent(iName, loc));

	const pushArgs: Node[] = [];
	pushArgs.push(makeArrayAccess(makeIdent(arrName, loc), makeIdent(iName, loc), loc));
	const pushStmts: Node[] = [];
	pushStmts.push(makeExprStmt(makeCall(makeMember(makeIdent(resName, loc), "push", loc), pushArgs, loc), loc));
	const emptyStmts: Node[] = [];
	bodyStmts.push(makeIf(makeCall(callbackExpr, filterArgs, loc), makeBlock(pushStmts, loc), makeBlock(emptyStmts, loc), loc));
	bodyStmts.push(makeIncrement(iName, loc));

	stmts.push(makeWhile(makeLengthCond(iName, arrName, loc), makeBlock(bodyStmts, loc), loc));
	return stmts;
}

function buildReduce(arrExpr: Node, callbackExpr: Node, initExpr: Node, arrName: string, accName: string, iName: string, loc: SourceLocation): Node[] {
	const stmts: Node[] = [];
	stmts.push(makeVarDecl(arrName, arrExpr, DeclKind.Const, loc));
	stmts.push(makeVarDecl(accName, initExpr, DeclKind.Let, loc));
	stmts.push(makeVarDecl(iName, makeNumber(0, loc), DeclKind.Let, loc));

	const bodyStmts: Node[] = [];
	const elem = makeArrayAccess(makeIdent(arrName, loc), makeIdent(iName, loc), loc);
	const reduceArgs: Node[] = [];
	reduceArgs.push(makeIdent(accName, loc));
	reduceArgs.push(elem);
	reduceArgs.push(makeIdent(iName, loc));
	bodyStmts.push(makeExprStmt(makeAssign(makeIdent(accName, loc), makeCall(callbackExpr, reduceArgs, loc), loc), loc));
	bodyStmts.push(makeIncrement(iName, loc));

	stmts.push(makeWhile(makeLengthCond(iName, arrName, loc), makeBlock(bodyStmts, loc), loc));
	return stmts;
}

// ===== Expander =====

function expandArrayMethodStmt(stmt: Node, ctx: TransformContext): Node[] {
	// ReturnStmt: return arr.map(fn) → loop stmts + return $result
	if (stmt.kind === NodeKind.ReturnStmt) {
		const d = stmt.data as ReturnStmtData;
		const method = getArrayMethodName(d.argument);
		if (method !== "") {
			const cd = d.argument.data as CallExprData;
			const arrExpr = (cd.callee.data as MemberExprData).object;
			const callback = cd.arguments[0];
			const loc = stmt.location;
			if (method === "map") {
				const arrName = freshTemp(ctx, "mArr");
				const resName = freshTemp(ctx, "mRes");
				const iName = freshTemp(ctx, "mI");
				const loopStmts = buildMap(arrExpr, callback, arrName, resName, iName, loc);
				loopStmts.push(makeReturn(makeIdent(resName, loc), loc));
				return loopStmts;
			}
			if (method === "filter") {
				const arrName = freshTemp(ctx, "fArr");
				const resName = freshTemp(ctx, "fRes");
				const iName = freshTemp(ctx, "fI");
				const loopStmts = buildFilter(arrExpr, callback, arrName, resName, iName, loc);
				loopStmts.push(makeReturn(makeIdent(resName, loc), loc));
				return loopStmts;
			}
			// reduce
			const initExpr = cd.arguments[1];
			const arrName = freshTemp(ctx, "rArr");
			const accName = freshTemp(ctx, "rAcc");
			const iName = freshTemp(ctx, "rI");
			const loopStmts = buildReduce(arrExpr, callback, initExpr, arrName, accName, iName, loc);
			loopStmts.push(makeReturn(makeIdent(accName, loc), loc));
			return loopStmts;
		}
	}
	// VariableDecl: const x = arr.map(fn) → loop stmts + const x = $result
	if (stmt.kind === NodeKind.VariableDecl) {
		const d = stmt.data as VariableDeclData;
		const method = getArrayMethodName(d.initializer);
		if (method !== "") {
			const cd = d.initializer.data as CallExprData;
			const arrExpr = (cd.callee.data as MemberExprData).object;
			const callback = cd.arguments[0];
			const loc = stmt.location;
			if (method === "map") {
				const arrName = freshTemp(ctx, "mArr");
				const resName = freshTemp(ctx, "mRes");
				const iName = freshTemp(ctx, "mI");
				const loopStmts = buildMap(arrExpr, callback, arrName, resName, iName, loc);
				loopStmts.push(makeVarDecl(d.declName, makeIdent(resName, loc), d.declKind, loc));
				return loopStmts;
			}
			if (method === "filter") {
				const arrName = freshTemp(ctx, "fArr");
				const resName = freshTemp(ctx, "fRes");
				const iName = freshTemp(ctx, "fI");
				const loopStmts = buildFilter(arrExpr, callback, arrName, resName, iName, loc);
				loopStmts.push(makeVarDecl(d.declName, makeIdent(resName, loc), d.declKind, loc));
				return loopStmts;
			}
			// reduce
			const initExpr = cd.arguments[1];
			const arrName = freshTemp(ctx, "rArr");
			const accName = freshTemp(ctx, "rAcc");
			const iName = freshTemp(ctx, "rI");
			const loopStmts = buildReduce(arrExpr, callback, initExpr, arrName, accName, iName, loc);
			loopStmts.push(makeVarDecl(d.declName, makeIdent(accName, loc), d.declKind, loc));
			return loopStmts;
		}
	}
	return [stmt];
}

// ===== Entry Point =====

export function lowerArrayMethodInline(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandArrayMethodStmt, ctx);
	return program;
}

// ===== Tests =====
test "return map expands to 5 stmts" { check(stmtCountAfter("return arr.map(fn);", lowerArrayMethodInline) === 5); }

test "return filter expands to 5 stmts" { check(stmtCountAfter("return arr.filter(fn);", lowerArrayMethodInline) === 5); }

test "return reduce expands to 5 stmts" { check(stmtCountAfter("return arr.reduce(fn, 0);", lowerArrayMethodInline) === 5); }

test "const map expands to 5 stmts" { check(stmtCountAfter("const x = arr.map(fn);", lowerArrayMethodInline) === 5); }

test "first stmt is VarDecl" { check(firstStmtKindAfter("return arr.map(fn);", lowerArrayMethodInline) === NodeKind.VariableDecl); }

test "non-map method unchanged" { check(stmtCountAfter("return arr.push(1);", lowerArrayMethodInline) === 1); }

test "plain call unchanged" { check(stmtCountAfter("return f();", lowerArrayMethodInline) === 1); }

test "non-method return unchanged" { check(stmtCountAfter("return x;", lowerArrayMethodInline) === 1); }

test "wrong arg count for map unchanged" { check(stmtCountAfter("return arr.map(fn, extra);", lowerArrayMethodInline) === 1); }

test "wrong arg count for reduce unchanged" { check(stmtCountAfter("return arr.reduce(fn);", lowerArrayMethodInline) === 1); }
