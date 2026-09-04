// Object Spread Lowering — expand `{ ...base, x: v }` into explicit per-field
// entries `{ f: base.f, x: v }` so both backends emit plain field assignments
// and the analyzer sees real member reads (DRC copy insertion).
//
//   { ...base, h: v }  →  { w: base.w, h: v }        (base: identifier)
//   { ...f(), h: v }   →  const $sprd_N = f(); { w: $sprd_N.w, h: v }
//
// Fields overridden by a later explicit key or a later spread are dropped at
// expansion (last-wins, TS semantics) — never assigned twice.
//
// Bails (literal left untouched) when the literal or operand type is not a
// known non-extern Struct, or when an impure operand sits where no statement
// hoist can reach (expression-bodied arrow). Extern (ImportC) types keep the
// native JS spread.

import { Node, NodeKind, DeclKind, ObjectLiteralData, SpreadExprData, SourceLocation, Type, TypeKind } from "../../ast/node";
import { peelThrough, PEEL_ALL, unwrapRef } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { TransformContext, freshTempSym } from "../context";
import { walkNode, walkExpandBlocks } from "../walker";
import { makeVarDecl, makeIdentResolved, makeMember } from "../util";
import { forEachChild } from "../../ast/visitor";
import { firstStmtKindAfter, stmtCountAfter } from "../testUtil";

function spreadStructOf(t: Type | null): Type | null {
	if (t === null) return null;
	const peeled = peelThrough(unwrapRef(t), PEEL_ALL);
	const s = peeled === null ? unwrapRef(t) : peeled;
	if (s === null) return null;
	if (s.kind !== TypeKind.Struct) return null;
	if (s.typeNames === null || s.typeChildren === null) return null;
	if (s.sym !== null && hasFlag(s.sym, SymbolFlag.ImportC)) return null;
	return s;
}

function structHasField(t: Type, name: string): boolean {
	for (const n of t.typeNames) {
		if (n === name) return true;
	}
	return false;
}

// ===== Stage 1: hoist non-identifier spread operands to peer temps =====

function maybeHoistOperands(lit: Node, ctx: TransformContext, decls: Node[]): void {
	const d = lit.data as ObjectLiteralData;
	if (spreadStructOf(lit.nodeType) === null) return;
	let i = 0;
	while (i < d.keys.length) {
		if (d.keys[i] === "..." && d.properties[i].kind === NodeKind.SpreadExpr) {
			const sd = d.properties[i].data as SpreadExprData;
			const arg = sd.spreadArg;
			if (arg.kind !== NodeKind.Identifier && spreadStructOf(arg.nodeType) !== null) {
				const t = arg.nodeType;
				const sym = freshTempSym(ctx, "sprd", t);
				const dcl = makeVarDecl(sym.name, arg, DeclKind.Const, lit.location);
				dcl.resolvedSym = sym;
				dcl.nodeType = t;
				const ref = makeIdentResolved(sym, lit.location);
				ref.nodeType = t;
				sd.spreadArg = ref;
				decls.push(dcl);
			}
		}
		i += 1;
	}
}

// Stops at function boundaries (their statements get their own expandStmt
// visit) and at nested blocks (walkExpandBlocks descends into them itself).
function scanForSpreads(node: Node, ctx: TransformContext, decls: Node[]): void {
	if (node === null) return;
	if (node.kind === NodeKind.ObjectLiteral) maybeHoistOperands(node, ctx, decls);
	forEachChild(node, (c: Node): void => {
		if (c === null) return;
		const k = c.kind;
		if (k === NodeKind.ArrowFunction || k === NodeKind.FunctionExpr
			|| k === NodeKind.FunctionDecl || k === NodeKind.MethodDecl
			|| k === NodeKind.BlockStmt) return;
		scanForSpreads(c, ctx, decls);
	});
}

function hoistSpreadStmt(stmt: Node, ctx: TransformContext): Node[] {
	const decls: Node[] = [];
	scanForSpreads(stmt, ctx, decls);
	if (decls.length === 0) return [stmt];
	const out: Node[] = [];
	for (const dcl of decls) out.push(dcl);
	out.push(stmt);
	return out;
}

// ===== Stage 2: expand spread entries into per-field member reads =====

function providedLater(d: ObjectLiteralData, idx: int32, name: string): boolean {
	let j = idx + 1;
	while (j < d.keys.length) {
		if (d.keys[j] === name) return true;
		if (d.keys[j] === "..." && d.properties[j].kind === NodeKind.SpreadExpr) {
			const arg = (d.properties[j].data as SpreadExprData).spreadArg;
			const src = spreadStructOf(arg.nodeType);
			if (src !== null && structHasField(src, name)) return true;
		}
		j += 1;
	}
	return false;
}

function expandLiteral(node: Node): Node {
	if (node.kind !== NodeKind.ObjectLiteral) return node;
	const d = node.data as ObjectLiteralData;
	let hasSpread = false;
	for (const k of d.keys) {
		if (k === "...") { hasSpread = true; break; }
	}
	if (!hasSpread) return node;
	const target0 = spreadStructOf(node.nodeType);
	if (target0 === null) return node;
	const target = target0;
	let i = 0;
	while (i < d.keys.length) {
		if (d.keys[i] === "...") {
			if (d.properties[i].kind !== NodeKind.SpreadExpr) return node;
			const arg = (d.properties[i].data as SpreadExprData).spreadArg;
			if (arg.kind !== NodeKind.Identifier || arg.resolvedSym === null) return node;
			if (spreadStructOf(arg.nodeType) === null) return node;
		}
		i += 1;
	}
	const newKeys: string[] = [];
	const newProps: Node[] = [];
	const newLocs: SourceLocation[] = [];
	const hasLocs = d.keyLocations !== null && d.keyLocations.length === d.keys.length;
	i = 0;
	while (i < d.keys.length) {
		if (d.keys[i] !== "...") {
			newKeys.push(d.keys[i]);
			newProps.push(d.properties[i]);
			if (hasLocs) newLocs.push(d.keyLocations[i]);
			i += 1;
			continue;
		}
		const sp = d.properties[i];
		const arg = (sp.data as SpreadExprData).spreadArg;
		const src0 = spreadStructOf(arg.nodeType);
		const sym0 = arg.resolvedSym;
		if (src0 === null || sym0 === null) return node;
		const src = src0;
		const argSym = sym0;
		let fi = 0;
		while (fi < src.typeNames.length) {
			const fname = src.typeNames[fi];
			if (!fname.startsWith("__") && structHasField(target, fname)
				&& !providedLater(d, i, fname)) {
				const ref = makeIdentResolved(argSym, sp.location);
				ref.nodeType = arg.nodeType;
				const mem = makeMember(ref, fname, sp.location);
				mem.nodeType = src.typeChildren[fi];
				newKeys.push(fname);
				newProps.push(mem);
				if (hasLocs) newLocs.push(d.keyLocations[i]);
			}
			fi += 1;
		}
		i += 1;
	}
	d.keys = newKeys;
	d.properties = newProps;
	if (hasLocs) d.keyLocations = newLocs;
	return node;
}

// ===== Entry Point =====

export function lowerObjectSpread(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, hoistSpreadStmt, ctx);
	return walkNode(program, expandLiteral);
}

// ===== Tests =====
// Type-dependent expansion needs checked nodeTypes — covered by fixedbugs
// bug094. These assert untyped passthrough only.

test "untyped literal passthrough" {
	assert firstStmtKindAfter("const x = { a: 1 };", lowerObjectSpread) === NodeKind.VariableDecl;
}

test "stmt count preserved" {
	assert stmtCountAfter("let a = 1; let b = 2;", lowerObjectSpread) === 2;
}
