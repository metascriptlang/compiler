// Destructuring Lowering — transforms DestructuringDecl → temp var + field access

import {
	Node, NodeKind, DeclKind, SourceLocation, Type, TypeKind, createNode,
	DestructuringDeclData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData, IdentifierData, SpreadExprData, VariableDeclData,
	ArrayLiteralData, ObjectLiteralData, ExprStmtData, BinaryExprData,
} from "../../ast/node";
import { TransformContext, freshTempSym, freshOwnedSym } from "../context";
import { noneType, int32Type, destrPositionalElemType, destrNamedFieldType, destrRestElemType, destrObjectRestType, destrObjectRestNames, destrHasRuntimeLength } from "../../checker/types";
import { walkExpandBlocks } from "../walker";
import { nullishLowered } from "../coercion/nullishCoalesce";
import { makeIdentResolved, makeVarDecl, makeNumber, makeArrayAccess, makeMember, makeCall, boolToDeclKind, makeWhile, makeBinary, makeAssign, makeExprStmt, makeBlock, makeHiddenAddr, makeTypedObjectLiteral, makeConditional, syntheticToken, runtimeRef } from "../util";
import { stmtCountAfter, firstStmtKindAfter, parseInput, makeCtx, getStmts } from "../testUtil";

// ===== Main Entry Point =====

export function lowerDestructuring(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandDestructuring, ctx);
	return program;
}

// Carried onto the synthetic index access so a later capture (lambda lifting)
// types the env field concretely; without it a destructured closure element
// defaults to `double`/void* in the captured env.
function destrElemType(base: Node, i: int32): Type {
	const t = destrPositionalElemType(base.nodeType, i as int32);
	return t != null ? t : (null as unknown as Type);
}

function arrayRestValue(base: Node, from: int32, restType: Type | null, loc: SourceLocation, ctx: TransformContext, items: Node[]): Node | null {
	if (ctx.jsBackend) {
		const sliceCallee = makeMember(base, "slice", loc);
		const sliceCall = makeCall(sliceCallee, [makeNumber(from, loc), makeMember(base, "length", loc)], loc);
		if (restType != null) sliceCall.nodeType = restType;
		return sliceCall;
	}
	if (restType == null) return null;
	// C backend: slice is a std method the checker resolves at check time;
	// transform-built member calls bypass that, so mirror lowerArraySpread's
	// accumulator + msGenericArrayPush loop instead.
	const accSym = freshTempSym(ctx, "destr", restType);
	const emptyLit = createNode(NodeKind.ArrayLiteral, { elements: [] }, syntheticToken(loc));
	emptyLit.nodeType = restType;
	const accDecl = makeVarDecl(accSym.name, emptyLit, DeclKind.Let, loc);
	accDecl.resolvedSym = accSym;
	accDecl.nodeType = restType;
	items.push(accDecl);
	const iSym = freshTempSym(ctx, "destri", int32Type());
	const iDecl = makeVarDecl(iSym.name, makeNumber(from, loc), DeclKind.Let, loc);
	iDecl.resolvedSym = iSym;
	iDecl.nodeType = int32Type();
	items.push(iDecl);
	const lenMember = makeMember(base, "length", loc);
	lenMember.nodeType = int32Type();
	const iv0 = makeIdentResolved(iSym, loc);
	iv0.nodeType = int32Type();
	const cond = makeBinary(iv0, "<", lenMember, loc);
	const iv1 = makeIdentResolved(iSym, loc);
	iv1.nodeType = int32Type();
	const refAcc = restType.kind == TypeKind.Ref && restType.typeReturn != null;
	const elemAccess = makeArrayAccess(base, iv1, loc);
	elemAccess.nodeType = refAcc ? restType.typeReturn.typeReturn : restType.typeReturn;
	const accRef = makeIdentResolved(accSym, loc);
	accRef.nodeType = restType;
	const pushCall = makeCall(runtimeRef("msGenericArrayPush", loc), [refAcc ? accRef : makeHiddenAddr(accRef, loc), elemAccess], loc);
	const pushStmt = makeExprStmt(pushCall, loc);
	const iv2 = makeIdentResolved(iSym, loc);
	iv2.nodeType = int32Type();
	const iv3 = makeIdentResolved(iSym, loc);
	iv3.nodeType = int32Type();
	const incr = makeExprStmt(makeAssign(iv2, makeBinary(iv3, "+", makeNumber(1, loc), loc), loc), loc);
	items.push(makeWhile(cond, makeBlock([pushStmt, incr], loc), loc));
	const restRef = makeIdentResolved(accSym, loc);
	restRef.nodeType = restType;
	return restRef;
}

// Expand array pattern [a, b, ...rest] → indexed access
export function expandArrayRet(
	pattern: Node, base: Node, declKind: DeclKind,
	loc: SourceLocation, ctx: TransformContext
): Node[] {
	const apd = pattern.data as ArrayPatternData;
	const items: Node[] = [];
	for (let i = 0; i < apd.patternElements.length; i += 1) {
		const elem = apd.patternElements[i];

		// Rest element: last + hasRestElement
		if (apd.hasRestElement && i == apd.patternElements.length - 1) {
			let idNode: Node | null = null as unknown as Node;
			if (elem.kind == NodeKind.Identifier) idNode = elem;
			else if (elem.kind == NodeKind.SpreadExpr) idNode = (elem.data as SpreadExprData).spreadArg;
			if (idNode != null && idNode.kind == NodeKind.Identifier && (idNode.data as IdentifierData).name != "_") {
				const id = idNode.data as IdentifierData;
				const restType = destrRestElemType(base.nodeType);
				const restValue = arrayRestValue(base, i, restType, loc, ctx, items);
				if (restValue != null) {
					const restDecl = makeVarDecl(id.name, restValue, declKind, loc);
					if (!ctx.jsBackend) restDecl.nodeType = restType;
					restDecl.resolvedSym = idNode.resolvedSym;
					items.push(restDecl);
				}
			}
			continue;
		}

		// Simple identifier binding
		if (elem.kind == NodeKind.Identifier) {
			const id = elem.data as IdentifierData;
			if (id.name != "_") {
				const access = makeArrayAccess(base, makeNumber(i, loc), loc);
				const elemType = destrElemType(base, i);
				if (elemType != null) access.nodeType = elemType;
				let init = access;
				if (i < apd.patternDefaults.length && apd.patternDefaults[i] != null) {
					const def = apd.patternDefaults[i];
					init = nullishLowered(access, def, loc, elemType, ctx);
					if (destrHasRuntimeLength(base.nodeType)) {
						const lenMember = makeMember(base, "length", loc);
						lenMember.nodeType = int32Type();
						const idx = makeNumber(i, loc);
						idx.nodeType = int32Type();
						const guarded = makeConditional(makeBinary(idx, "<", lenMember, loc), init, def, loc);
						guarded.nodeType = init.nodeType;
						init = guarded;
					}
				}
				const elemDecl = makeVarDecl(id.name, init, declKind, loc);
				elemDecl.resolvedSym = elem.resolvedSym;
				items.push(elemDecl);
			}
		}
	}
	return items;
}

// Expand object pattern {x, y: z} → member access
export function expandObjectRet(
	pattern: Node, base: Node, declKind: DeclKind,
	loc: SourceLocation, ctx: TransformContext
): Node[] {
	const opd = pattern.data as ObjectPatternData;
	const items: Node[] = [];
	const takenKeys: string[] = [];
	for (const prop of opd.patternProps) {
		if (prop.kind == NodeKind.ObjectPatternProp) takenKeys.push((prop.data as ObjectPatternPropData).propKey);
	}
	for (const prop of opd.patternProps) {
		if (prop.kind == NodeKind.SpreadExpr) {
			const inner = (prop.data as SpreadExprData).spreadArg;
			if (inner.kind != NodeKind.Identifier) continue;
			const restId = inner.data as IdentifierData;
			if (restId.name == "_") continue;
			const restType = destrObjectRestType(base.nodeType, takenKeys);
			if (restType == null) continue;
			const restNames = destrObjectRestNames(base.nodeType, takenKeys);
			const restValues: Node[] = [];
			for (const fieldName of restNames) {
				const fieldAccess = makeMember(base, fieldName, loc);
				const ft = destrNamedFieldType(base.nodeType, fieldName);
				if (ft != null) fieldAccess.nodeType = ft;
				restValues.push(fieldAccess);
			}
			const restDecl = makeVarDecl(restId.name, makeTypedObjectLiteral(restNames, restValues, restType, loc), declKind, loc);
			restDecl.nodeType = restType;
			restDecl.resolvedSym = inner.resolvedSym;
			items.push(restDecl);
			continue;
		}
		if (prop.kind != NodeKind.ObjectPatternProp) continue;
		const p = prop.data as ObjectPatternPropData;
		if (p.propAlias.kind == NodeKind.Identifier) {
			const id = p.propAlias.data as IdentifierData;
			const memberAccess = makeMember(base, p.propKey, loc);
			const fieldType = destrNamedFieldType(base.nodeType, p.propKey);
			if (fieldType != null) memberAccess.nodeType = fieldType;
			let init = memberAccess;
			if (p.propDefault != null) init = nullishLowered(memberAccess, p.propDefault, loc, fieldType, ctx);
			const propDecl = makeVarDecl(id.name, init, declKind, loc);
			propDecl.resolvedSym = p.propAlias.resolvedSym;
			items.push(propDecl);
		}
	}
	return items;
}

function isGrowableArray(t: Type | null): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Ref && t.typeReturn != null) return t.typeReturn.kind == TypeKind.Array;
	return t.kind == TypeKind.Array;
}

function isPattern(n: Node): boolean {
	return n.kind == NodeKind.ArrayLiteral || n.kind == NodeKind.ObjectLiteral;
}

function tempOf(value: Node, loc: SourceLocation, ctx: TransformContext, items: Node[]): Node {
	const sym = freshOwnedSym(ctx, "destr", value.nodeType != null ? value.nodeType : noneType());
	const decl = makeVarDecl(sym.name, value, DeclKind.Const, loc);
	decl.resolvedSym = sym;
	items.push(decl);
	return makeIdentResolved(sym, loc);
}

function assignTarget(target: Node, value: Node, loc: SourceLocation, ctx: TransformContext, items: Node[]): void {
	if (isPattern(target)) {
		assignPattern(target, tempOf(value, loc, ctx, items), loc, ctx, items);
		return;
	}
	if (target.kind != NodeKind.Identifier && target.kind != NodeKind.MemberExpr && target.kind != NodeKind.ArrayAccess) {
		ctx.errors.push(`${target.location.line}:${target.location.column}: a destructuring assignment target must be a variable, a field or an element`);
		return;
	}
	items.push(makeExprStmt(makeAssign(target, value, loc), loc));
}

function assignPattern(pattern: Node, base: Node, loc: SourceLocation, ctx: TransformContext, items: Node[]): void {
	if (pattern.kind == NodeKind.ArrayLiteral) {
		const elements = (pattern.data as ArrayLiteralData).elements;
		for (let i = 0; i < elements.length; i += 1) {
			const target = elements[i];
			if (target.kind == NodeKind.SpreadExpr) {
				const restTarget = (target.data as SpreadExprData).spreadArg;
				const restType = isGrowableArray(restTarget.nodeType) ? restTarget.nodeType : destrRestElemType(base.nodeType);
				const rest = i == elements.length - 1 ? arrayRestValue(base, i, restType, loc, ctx, items) : null;
				if (rest == null) {
					ctx.errors.push(`${target.location.line}:${target.location.column}: a rest element in a destructuring assignment must be the last one, over an array`);
					continue;
				}
				assignTarget((target.data as SpreadExprData).spreadArg, rest, loc, ctx, items);
				continue;
			}
			const access = makeArrayAccess(base, makeNumber(i, loc), loc);
			const elemType = destrElemType(base, i);
			if (elemType != null) access.nodeType = elemType;
			assignTarget(target, access, loc, ctx, items);
		}
		return;
	}
	const od = pattern.data as ObjectLiteralData;
	for (let i = 0; i < od.properties.length; i += 1) {
		const target = od.properties[i];
		if (target.kind == NodeKind.SpreadExpr) {
			ctx.errors.push(`${target.location.line}:${target.location.column}: a rest property in a destructuring assignment is not supported; destructure into a declaration`);
			continue;
		}
		const access = makeMember(base, od.keys[i], loc);
		const fieldType = destrNamedFieldType(base.nodeType, od.keys[i]);
		if (fieldType != null) access.nodeType = fieldType;
		assignTarget(target, access, loc, ctx, items);
	}
}

function expandPatternAssign(stmt: Node, ctx: TransformContext): Node[] {
	const e = (stmt.data as ExprStmtData).expr;
	if (e.kind != NodeKind.BinaryExpr) return [stmt];
	const bd = e.data as BinaryExprData;
	if (bd.operator != "=" || !isPattern(bd.left)) return [stmt];
	const items: Node[] = [];
	assignPattern(bd.left, tempOf(bd.right, stmt.location, ctx, items), stmt.location, ctx, items);
	return items;
}

function expandDestructuring(stmt: Node, ctx: TransformContext): Node[] {
	if (stmt.kind == NodeKind.ExprStmt) return expandPatternAssign(stmt, ctx);
	if (stmt.kind != NodeKind.DestructuringDecl) return [stmt];
	const d = stmt.data as DestructuringDeclData;
	const loc = stmt.location;
	const result: Node[] = [];

	// Simple RHS (identifier/member/access) → skip temp
	let baseExpr: Node | null = null;
	const initKind = d.destrInit.kind;
	if (initKind == NodeKind.Identifier || initKind == NodeKind.MemberExpr || initKind == NodeKind.ArrayAccess) {
		baseExpr = d.destrInit;
	} else {
		const sym = freshTempSym(ctx, "destr", d.destrInit.nodeType != null ? d.destrInit.nodeType : noneType());
		const tempDecl = makeVarDecl(sym.name, d.destrInit, DeclKind.Const, loc);
		tempDecl.resolvedSym = sym;
		// Propagate type so nativeLower can rewrite tuple access (t[0] → t._0)
		if (d.destrInit.nodeType != null) {
			tempDecl.nodeType = d.destrInit.nodeType;
		}
		result.push(tempDecl);
		baseExpr = makeIdentResolved(sym, loc);
	}

	const dk = boolToDeclKind(d.destrIsConst);
	if (d.destrPattern.kind == NodeKind.ArrayPattern) {
		const expanded = expandArrayRet(d.destrPattern, baseExpr, dk, loc, ctx);
		for (const node of expanded) {
			result.push(node);
		}
	}
	if (d.destrPattern.kind == NodeKind.ObjectPattern) {
		const expanded = expandObjectRet(d.destrPattern, baseExpr, dk, loc, ctx);
		for (const node of expanded) {
			result.push(node);
		}
	}

	return result;
}

// ===== Tests =====
test "array 2 elements" { assert stmtCountAfter("const [a, b] = f();", lowerDestructuring) == 3; }

test "first stmt is temp VarDecl" { assert firstStmtKindAfter("const [a, b] = f();", lowerDestructuring) == NodeKind.VariableDecl; }

test "object destructuring" { assert stmtCountAfter("const { x, y } = f();", lowerDestructuring) == 3; }

test "simple RHS skips temp" { assert stmtCountAfter("const [a, b] = myVar;", lowerDestructuring) == 2; }

test "non-destructuring passthrough" { assert stmtCountAfter("const x = 1;", lowerDestructuring) == 1; }

test "preserves surrounding stmts" { assert stmtCountAfter("let z = 0; const [a, b] = f(); let w = 1;", lowerDestructuring) == 5; }

function lastInitKind(input: string): NodeKind {
	const parsed = parseInput(input);
	if (!parsed.ok) return NodeKind.Program;
	const stmts = getStmts(lowerDestructuring(parsed.value, makeCtx()));
	if (stmts.length == 0) return NodeKind.Program;
	const last = stmts[stmts.length - 1];
	if (last.kind != NodeKind.VariableDecl) return last.kind;
	return (last.data as VariableDeclData).initializer.kind;
}

test "object default lowers to a conditional init" { assert lastInitKind("const { x = 1 } = f();") == NodeKind.ConditionalExpr; }

test "array default lowers to a conditional init" { assert lastInitKind("const [a = 1] = f();") == NodeKind.ConditionalExpr; }

test "no default keeps a bare access" { assert lastInitKind("const { x } = f();") == NodeKind.MemberExpr; }

test "a pattern assignment evaluates its right side once into a temp" { assert stmtCountAfter("[a, b] = [b, a];", lowerDestructuring) == 3; }

test "a nested pattern assignment takes one temp per level" { assert stmtCountAfter("[a, [b, c]] = f();", lowerDestructuring) == 5; }

test "an assignment to a plain target passes through" { assert stmtCountAfter("a = [b];", lowerDestructuring) == 1; }
