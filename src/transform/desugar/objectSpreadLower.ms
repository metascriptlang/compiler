// Object Spread Lowering — expand `{ ...base, x: v }` into explicit per-field
// entries `{ f: base.f, x: v }` so both backends emit plain field assignments
// and the analyzer sees real member reads (DRC copy insertion).
//
//   { ...base, h: v }  →  { w: base.w, h: v }        (base: identifier)
//   { ...f(), h: v }   →  const $sprd_N = f(); { w: $sprd_N.w, h: v }
//
// Fields overridden by a later explicit key or a later spread are dropped at
// expansion (last-wins, TS semantics) — never assigned twice. A spread field
// declared optional keeps the value before it when it holds null:
//
//   { a: v, ...p }     →  { a: p.a ?? v }             (p.a declared `a?:`)
//
// Bails (literal left untouched) when the literal or operand type is not a
// known non-extern Struct, or when an impure operand sits where no statement
// hoist can reach (expression-bodied arrow). Extern (ImportC) types keep the
// native JS spread.

import { Node, NodeKind, DeclKind, ObjectLiteralData, SpreadExprData, MemberExprData, SourceLocation, Type, TypeKind } from "../../ast/node";
import { peelThrough, PEEL_ALL, unwrapRef, peelToStructOrUnion } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { TransformContext, freshTempSym } from "../context";
import { walkNode, walkExpandBlocks, walkOnceEvaluated, OnceEvalState } from "../walker";
import { makeVarDecl, makeIdentResolved, makeMember } from "../util";
import { nullishLowered } from "../coercion/nullishCoalesce";
import { forEachChild } from "../../ast/visitor";
import { firstStmtKindAfter, stmtCountAfter } from "../testUtil";
import { fitJoinedBranch } from "../../checker/fit";
import { lowerImplicitConv } from "../coercion/implicitConvLower";

export function spreadStructOf(t: Type | null): Type | null {
	if (t == null) return null;
	const peeled = peelThrough(unwrapRef(t), PEEL_ALL);
	const view = peeled == null ? unwrapRef(t) : peeled;
	const s = view.kind == TypeKind.GenericInstance && view.typeReturn != null ? unwrapRef(view.typeReturn) : view;
	if (s.kind != TypeKind.Struct) return null;
	if (s.typeNames == null || s.typeChildren == null) return null;
	if (s.sym != null && hasFlag(s.sym, SymbolFlag.ImportC)) return null;
	return s;
}

function builtStructOf(lit: Node): Type | null {
	const own = spreadStructOf(lit.nodeType);
	if (own != null || lit.variantSlot <= 0) return own;
	const u = peelToStructOrUnion(lit.nodeType);
	if (u == null || u.kind != TypeKind.Union || u.typeChildren == null || lit.variantSlot > u.typeChildren.length) return null;
	return spreadStructOf(u.typeChildren[lit.variantSlot - 1]);
}

function structHasField(t: Type, name: string): boolean {
	for (const n of t.typeNames) {
		if (n == name) return true;
	}
	return false;
}

function declaredOptional(t: Type, name: string): boolean {
	return t.optionalFields != null && t.optionalFields.includes(name);
}

function spreadSourceAt(d: ObjectLiteralData, j: int32): Type | null {
	if (d.keys[j] != "..." || d.properties[j].kind != NodeKind.SpreadExpr) return null;
	return spreadStructOf((d.properties[j].data as SpreadExprData).spreadArg.nodeType);
}

// A value read again only when a later optional spread field holds null.
function isPlainValue(n: Node): boolean {
	const k = n.kind;
	if (k == NodeKind.Identifier || k == NodeKind.NumberLiteral || k == NodeKind.StringLiteral
		|| k == NodeKind.BooleanLiteral || k == NodeKind.NullLiteral) return true;
	return k == NodeKind.MemberExpr && isPlainValue((n.data as MemberExprData).object);
}

function keptByLaterOptional(d: ObjectLiteralData, idx: int32, name: string): boolean {
	let j = idx + 1;
	while (j < d.keys.length) {
		if (d.keys[j] == name) return false;
		const src = spreadSourceAt(d, j);
		if (src != null && structHasField(src, name)) return declaredOptional(src, name);
		j += 1;
	}
	return false;
}

function fitIntoField(value: Node, target: Type, name: string, ctx: TransformContext): Node {
	const at = target.typeNames.indexOf(name);
	if (at < 0 || at >= target.typeChildren.length || ctx.checkerCtx == null) return value;
	return lowerImplicitConv(fitJoinedBranch(ctx.checkerCtx, value, target.typeChildren[at]), ctx);
}

// ===== Stage 1: hoist non-identifier spread operands to peer temps =====

function maybeHoistOperands(lit: Node, ctx: TransformContext, decls: Node[], safe: Node[] | null): void {
	const d = lit.data as ObjectLiteralData;
	if (builtStructOf(lit) == null) return;
	let i = 0;
	while (i < d.keys.length) {
		if (d.keys[i] == "..." && d.properties[i].kind == NodeKind.SpreadExpr && (safe == null || safe.includes(d.properties[i]))) {
			const sd = d.properties[i].data as SpreadExprData;
			const arg = sd.spreadArg;
			if (arg.kind != NodeKind.Identifier && spreadStructOf(arg.nodeType) != null) {
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
		} else if (d.keys[i] != "..." && !isPlainValue(d.properties[i]) && (safe == null || safe.includes(d.properties[i]))
			&& keptByLaterOptional(d, i, d.keys[i])) {
			const v = d.properties[i];
			const sym = freshTempSym(ctx, "kept", v.nodeType);
			const dcl = makeVarDecl(sym.name, v, DeclKind.Const, lit.location);
			dcl.resolvedSym = sym;
			dcl.nodeType = v.nodeType;
			const ref = makeIdentResolved(sym, lit.location);
			ref.nodeType = v.nodeType;
			d.properties[i] = ref;
			decls.push(dcl);
		}
		i += 1;
	}
}

// Stops at function boundaries (their statements get their own expandStmt
// visit) and at nested blocks (walkExpandBlocks descends into them itself).
function scanForSpreads(node: Node, ctx: TransformContext, decls: Node[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.ObjectLiteral) maybeHoistOperands(node, ctx, decls, null);
	forEachChild(node, (c: Node): void => {
		if (c == null) return;
		const k = c.kind;
		if (k == NodeKind.ArrowFunction || k == NodeKind.FunctionExpr
			|| k == NodeKind.FunctionDecl || k == NodeKind.MethodDecl
			|| k == NodeKind.BlockStmt) return;
		scanForSpreads(c, ctx, decls);
	});
}

function hoistLeadingSpreadStmt(stmt: Node, ctx: TransformContext): Node[] {
	const decls: Node[] = [];
	const safe: Node[] = [];
	const st: OnceEvalState = { effectSeen: false };
	walkOnceEvaluated(stmt, st, (n: Node, effectBefore: boolean): void => {
		if (!effectBefore) safe.push(n);
		if (n.kind == NodeKind.ObjectLiteral) maybeHoistOperands(n, ctx, decls, safe);
	});
	return prependDecls(stmt, decls);
}

function hoistSpreadStmt(stmt: Node, ctx: TransformContext): Node[] {
	const decls: Node[] = [];
	scanForSpreads(stmt, ctx, decls);
	return prependDecls(stmt, decls);
}

function prependDecls(stmt: Node, decls: Node[]): Node[] {
	if (decls.length == 0) return [stmt];
	const out: Node[] = [];
	for (const dcl of decls) out.push(dcl);
	out.push(stmt);
	return out;
}

// ===== Stage 2: expand spread entries into per-field member reads =====

function providerOf(keys: string[], dropped: boolean[], name: string): int32 {
	let j = keys.length - 1;
	while (j >= 0) {
		if (!dropped[j] && keys[j] == name) return j;
		j -= 1;
	}
	return -1;
}

export function expandObjectSpread(node: Node, ctx: TransformContext): Node {
	if (node.kind != NodeKind.ObjectLiteral) return node;
	const d = node.data as ObjectLiteralData;
	let hasSpread = false;
	for (const k of d.keys) {
		if (k == "...") { hasSpread = true; break; }
	}
	if (!hasSpread) return node;
	const target0 = builtStructOf(node);
	if (target0 == null) return node;
	const target = target0;
	let i = 0;
	while (i < d.keys.length) {
		if (d.keys[i] == "...") {
			if (d.properties[i].kind != NodeKind.SpreadExpr) return node;
			const arg = (d.properties[i].data as SpreadExprData).spreadArg;
			if (arg.kind != NodeKind.Identifier || arg.resolvedSym == null) return node;
			if (spreadStructOf(arg.nodeType) == null) return node;
		} else if (!isPlainValue(d.properties[i]) && keptByLaterOptional(d, i, d.keys[i])) {
			return node;
		}
		i += 1;
	}
	const newKeys: string[] = [];
	const newProps: Node[] = [];
	const newLocs: SourceLocation[] = [];
	const dropped: boolean[] = [];
	const fromSpread: boolean[] = [];
	const hasLocs = d.keyLocations != null && d.keyLocations.length == d.keys.length;
	i = 0;
	while (i < d.keys.length) {
		if (d.keys[i] != "...") {
			const before = providerOf(newKeys, dropped, d.keys[i]);
			if (before >= 0) dropped[before] = true;
			newKeys.push(d.keys[i]);
			newProps.push(d.properties[i]);
			dropped.push(false);
			fromSpread.push(false);
			if (hasLocs) newLocs.push(d.keyLocations[i]);
			i += 1;
			continue;
		}
		const sp = d.properties[i];
		const arg = (sp.data as SpreadExprData).spreadArg;
		const src0 = spreadStructOf(arg.nodeType);
		const sym0 = arg.resolvedSym;
		if (src0 == null || sym0 == null) return node;
		const src = src0;
		const argSym = sym0;
		let fi = 0;
		while (fi < src.typeNames.length) {
			const fname = src.typeNames[fi];
			if (!fname.startsWith("__") && structHasField(target, fname)) {
				const ref = makeIdentResolved(argSym, sp.location);
				ref.nodeType = arg.nodeType;
				const mem = makeMember(ref, fname, sp.location);
				mem.nodeType = src.typeChildren[fi];
				const before = providerOf(newKeys, dropped, fname);
				if (before >= 0 && declaredOptional(src, fname)) {
					const at = target.typeNames.indexOf(fname);
					const slot = at >= 0 && at < target.typeChildren.length ? target.typeChildren[at] : null;
					newProps[before] = nullishLowered(mem, fitIntoField(newProps[before], target, fname, ctx), sp.location, slot, ctx);
					fromSpread[before] = false;
				} else {
					if (before >= 0) dropped[before] = true;
					newKeys.push(fname);
					newProps.push(mem);
					dropped.push(false);
					fromSpread.push(true);
					if (hasLocs) newLocs.push(d.keyLocations[i]);
				}
			}
			fi += 1;
		}
		i += 1;
	}
	const keys: string[] = [];
	const props: Node[] = [];
	const locs: SourceLocation[] = [];
	i = 0;
	while (i < newKeys.length) {
		if (!dropped[i]) {
			keys.push(newKeys[i]);
			props.push(fromSpread[i] ? fitIntoField(newProps[i], target, newKeys[i], ctx) : newProps[i]);
			if (hasLocs) locs.push(newLocs[i]);
		}
		i += 1;
	}
	d.keys = keys;
	d.properties = props;
	if (hasLocs) d.keyLocations = locs;
	return node;
}

// ===== Entry Point =====

export function lowerObjectSpread(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, hoistLeadingSpreadStmt, ctx);
	return walkNode(program, (n: Node): Node => expandObjectSpread(n, ctx));
}

export function lowerObjectSpreadEager(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, hoistSpreadStmt, ctx);
	return walkNode(program, (n: Node): Node => expandObjectSpread(n, ctx));
}

// ===== Tests =====
// Type-dependent expansion needs checked nodeTypes — covered by fixedbugs
// bug094. These assert untyped passthrough only.

test "untyped literal passthrough" {
	assert firstStmtKindAfter("const x = { a: 1 };", lowerObjectSpread) == NodeKind.VariableDecl;
}

test "stmt count preserved" {
	assert stmtCountAfter("let a = 1; let b = 2;", lowerObjectSpread) == 2;
}
