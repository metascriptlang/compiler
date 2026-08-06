// Array Method Inline — arr.map/filter/reduce → inline while loops
// Follows standard reference expansion pattern for zero call overhead array methods.
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
import { TransformContext, freshTempSym } from "../context";
import { noneType, int32Type } from "../../checker/types";
import { Symbol } from "../../ast/node";
import { walkExpandBlocks } from "../walker";
import {
	makeVarDecl, makeIdentResolved, makeCall, makeMember, makeExprStmt, makeBlock,
	makeReturn, makeWhile, makeBinary, makeNumber, makeAssign, makeArrayAccess,
	makeIf, syntheticToken,
} from "../util";
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

function makeIncrement(iSym: Symbol, loc: SourceLocation): Node {
	return makeExprStmt(makeAssign(
		makeIdentResolved(iSym, loc),
		makeBinary(makeIdentResolved(iSym, loc), "+", makeNumber(1, loc), loc),
	loc), loc);
}

function makeLengthCond(iSym: Symbol, arrSym: Symbol, loc: SourceLocation): Node {
	return makeBinary(makeIdentResolved(iSym, loc), "<", makeMember(makeIdentResolved(arrSym, loc), "length", loc), loc);
}

// ===== Loop Builders =====
// Each returns Node[] of the loop setup + while. Caller appends final return/varDecl.

function buildMap(arrExpr: Node, callbackExpr: Node, arrSym: Symbol, resSym: Symbol, iSym: Symbol, loc: SourceLocation): Node[] {
	const stmts: Node[] = [];
	const arrDecl = makeVarDecl(arrSym.name, arrExpr, DeclKind.Const, loc);
	arrDecl.resolvedSym = arrSym;
	stmts.push(arrDecl);
	const resDecl = makeVarDecl(resSym.name, makeEmptyArray(loc), DeclKind.Const, loc);
	resDecl.resolvedSym = resSym;
	stmts.push(resDecl);
	const iDecl = makeVarDecl(iSym.name, makeNumber(0, loc), DeclKind.Let, loc);
	iDecl.resolvedSym = iSym;
	stmts.push(iDecl);

	const bodyStmts: Node[] = [];
	const elem = makeArrayAccess(makeIdentResolved(arrSym, loc), makeIdentResolved(iSym, loc), loc);
	const callArgs: Node[] = [];
	callArgs.push(elem);
	callArgs.push(makeIdentResolved(iSym, loc));
	const pushArgs: Node[] = [];
	pushArgs.push(makeCall(callbackExpr, callArgs, loc));
	bodyStmts.push(makeExprStmt(makeCall(makeMember(makeIdentResolved(resSym, loc), "push", loc), pushArgs, loc), loc));
	bodyStmts.push(makeIncrement(iSym, loc));

	stmts.push(makeWhile(makeLengthCond(iSym, arrSym, loc), makeBlock(bodyStmts, loc), loc));
	return stmts;
}

function buildFilter(arrExpr: Node, callbackExpr: Node, arrSym: Symbol, resSym: Symbol, iSym: Symbol, loc: SourceLocation): Node[] {
	const stmts: Node[] = [];
	const arrDecl = makeVarDecl(arrSym.name, arrExpr, DeclKind.Const, loc);
	arrDecl.resolvedSym = arrSym;
	stmts.push(arrDecl);
	const resDecl = makeVarDecl(resSym.name, makeEmptyArray(loc), DeclKind.Const, loc);
	resDecl.resolvedSym = resSym;
	stmts.push(resDecl);
	const iDecl = makeVarDecl(iSym.name, makeNumber(0, loc), DeclKind.Let, loc);
	iDecl.resolvedSym = iSym;
	stmts.push(iDecl);

	const bodyStmts: Node[] = [];
	const elem = makeArrayAccess(makeIdentResolved(arrSym, loc), makeIdentResolved(iSym, loc), loc);
	const filterArgs: Node[] = [];
	filterArgs.push(elem);
	filterArgs.push(makeIdentResolved(iSym, loc));

	const pushArgs: Node[] = [];
	pushArgs.push(makeArrayAccess(makeIdentResolved(arrSym, loc), makeIdentResolved(iSym, loc), loc));
	const pushStmts: Node[] = [];
	pushStmts.push(makeExprStmt(makeCall(makeMember(makeIdentResolved(resSym, loc), "push", loc), pushArgs, loc), loc));
	const emptyStmts: Node[] = [];
	bodyStmts.push(makeIf(makeCall(callbackExpr, filterArgs, loc), makeBlock(pushStmts, loc), makeBlock(emptyStmts, loc), loc));
	bodyStmts.push(makeIncrement(iSym, loc));

	stmts.push(makeWhile(makeLengthCond(iSym, arrSym, loc), makeBlock(bodyStmts, loc), loc));
	return stmts;
}

function buildReduce(arrExpr: Node, callbackExpr: Node, initExpr: Node, arrSym: Symbol, accSym: Symbol, iSym: Symbol, loc: SourceLocation): Node[] {
	const stmts: Node[] = [];
	const arrDecl = makeVarDecl(arrSym.name, arrExpr, DeclKind.Const, loc);
	arrDecl.resolvedSym = arrSym;
	stmts.push(arrDecl);
	const accDecl = makeVarDecl(accSym.name, initExpr, DeclKind.Let, loc);
	accDecl.resolvedSym = accSym;
	stmts.push(accDecl);
	const iDecl = makeVarDecl(iSym.name, makeNumber(0, loc), DeclKind.Let, loc);
	iDecl.resolvedSym = iSym;
	stmts.push(iDecl);

	const bodyStmts: Node[] = [];
	const elem = makeArrayAccess(makeIdentResolved(arrSym, loc), makeIdentResolved(iSym, loc), loc);
	const reduceArgs: Node[] = [];
	reduceArgs.push(makeIdentResolved(accSym, loc));
	reduceArgs.push(elem);
	reduceArgs.push(makeIdentResolved(iSym, loc));
	bodyStmts.push(makeExprStmt(makeAssign(makeIdentResolved(accSym, loc), makeCall(callbackExpr, reduceArgs, loc), loc), loc));
	bodyStmts.push(makeIncrement(iSym, loc));

	stmts.push(makeWhile(makeLengthCond(iSym, arrSym, loc), makeBlock(bodyStmts, loc), loc));
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
				const arrSym = freshTempSym(ctx, "mArr", arrExpr.nodeType !== null ? arrExpr.nodeType : noneType());
				const resSym = freshTempSym(ctx, "mRes", noneType());
				const iSym = freshTempSym(ctx, "mI", int32Type());
				const loopStmts = buildMap(arrExpr, callback, arrSym, resSym, iSym, loc);
				loopStmts.push(makeReturn(makeIdentResolved(resSym, loc), loc));
				return loopStmts;
			}
			if (method === "filter") {
				const arrSym = freshTempSym(ctx, "fArr", arrExpr.nodeType !== null ? arrExpr.nodeType : noneType());
				const resSym = freshTempSym(ctx, "fRes", noneType());
				const iSym = freshTempSym(ctx, "fI", int32Type());
				const loopStmts = buildFilter(arrExpr, callback, arrSym, resSym, iSym, loc);
				loopStmts.push(makeReturn(makeIdentResolved(resSym, loc), loc));
				return loopStmts;
			}
			// reduce
			const initExpr = cd.arguments[1];
			const arrSym = freshTempSym(ctx, "rArr", arrExpr.nodeType !== null ? arrExpr.nodeType : noneType());
			const accSym = freshTempSym(ctx, "rAcc", initExpr.nodeType !== null ? initExpr.nodeType : noneType());
			const iSym = freshTempSym(ctx, "rI", int32Type());
			const loopStmts = buildReduce(arrExpr, callback, initExpr, arrSym, accSym, iSym, loc);
			loopStmts.push(makeReturn(makeIdentResolved(accSym, loc), loc));
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
				const arrSym = freshTempSym(ctx, "mArr", arrExpr.nodeType !== null ? arrExpr.nodeType : noneType());
				const resSym = freshTempSym(ctx, "mRes", noneType());
				const iSym = freshTempSym(ctx, "mI", int32Type());
				const loopStmts = buildMap(arrExpr, callback, arrSym, resSym, iSym, loc);
				loopStmts.push(makeVarDecl(d.declName, makeIdentResolved(resSym, loc), d.declKind, loc));
				return loopStmts;
			}
			if (method === "filter") {
				const arrSym = freshTempSym(ctx, "fArr", arrExpr.nodeType !== null ? arrExpr.nodeType : noneType());
				const resSym = freshTempSym(ctx, "fRes", noneType());
				const iSym = freshTempSym(ctx, "fI", int32Type());
				const loopStmts = buildFilter(arrExpr, callback, arrSym, resSym, iSym, loc);
				loopStmts.push(makeVarDecl(d.declName, makeIdentResolved(resSym, loc), d.declKind, loc));
				return loopStmts;
			}
			// reduce
			const initExpr = cd.arguments[1];
			const arrSym = freshTempSym(ctx, "rArr", arrExpr.nodeType !== null ? arrExpr.nodeType : noneType());
			const accSym = freshTempSym(ctx, "rAcc", initExpr.nodeType !== null ? initExpr.nodeType : noneType());
			const iSym = freshTempSym(ctx, "rI", int32Type());
			const loopStmts = buildReduce(arrExpr, callback, initExpr, arrSym, accSym, iSym, loc);
			loopStmts.push(makeVarDecl(d.declName, makeIdentResolved(accSym, loc), d.declKind, loc));
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
test "return map expands to 5 stmts" { assert stmtCountAfter("return arr.map(fn);", lowerArrayMethodInline) === 5; }

test "return filter expands to 5 stmts" { assert stmtCountAfter("return arr.filter(fn);", lowerArrayMethodInline) === 5; }

test "return reduce expands to 5 stmts" { assert stmtCountAfter("return arr.reduce(fn, 0);", lowerArrayMethodInline) === 5; }

test "const map expands to 5 stmts" { assert stmtCountAfter("const x = arr.map(fn);", lowerArrayMethodInline) === 5; }

test "first stmt is VarDecl" { assert firstStmtKindAfter("return arr.map(fn);", lowerArrayMethodInline) === NodeKind.VariableDecl; }

test "non-map method unchanged" { assert stmtCountAfter("return arr.push(1);", lowerArrayMethodInline) === 1; }

test "plain call unchanged" { assert stmtCountAfter("return f();", lowerArrayMethodInline) === 1; }

test "non-method return unchanged" { assert stmtCountAfter("return x;", lowerArrayMethodInline) === 1; }

test "wrong arg count for map unchanged" { assert stmtCountAfter("return arr.map(fn, extra);", lowerArrayMethodInline) === 1; }

test "wrong arg count for reduce unchanged" { assert stmtCountAfter("return arr.reduce(fn);", lowerArrayMethodInline) === 1; }
