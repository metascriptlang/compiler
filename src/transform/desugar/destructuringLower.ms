// Destructuring Lowering — transforms DestructuringDecl → temp var + field access

import {
	Node, NodeKind, DeclKind, SourceLocation, Type, TypeKind, createNode,
	DestructuringDeclData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData, IdentifierData, SpreadExprData, VariableDeclData,
} from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { noneType, int32Type, destrPositionalElemType, destrNamedFieldType, destrRestElemType, destrObjectRestType, destrObjectRestNames, destrHasRuntimeLength } from "../../checker/types";
import { walkExpandBlocks } from "../walker";
import { nullishLowered } from "../coercion/nullishCoalesce";
import { makeIdentResolved, makeVarDecl, makeNumber, makeArrayAccess, makeMember, makeCall, boolToDeclKind, makeIdent, makeWhile, makeBinary, makeAssign, makeExprStmt, makeBlock, makeHiddenAddr, makeTypedObjectLiteral, makeConditional, syntheticToken } from "../util";
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
				if (ctx.jsBackend) {
					const sliceCallee = makeMember(base, "slice", loc);
					const sliceCall = makeCall(sliceCallee, [makeNumber(i, loc), makeMember(base, "length", loc)], loc);
					if (restType != null) sliceCall.nodeType = restType;
					items.push(makeVarDecl(id.name, sliceCall, declKind, loc));
				} else if (restType != null) {
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
					const iDecl = makeVarDecl(iSym.name, makeNumber(i, loc), DeclKind.Let, loc);
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
					const elemAccess = makeArrayAccess(base, iv1, loc);
					elemAccess.nodeType = restType.typeReturn;
					const accRef = makeIdentResolved(accSym, loc);
					accRef.nodeType = restType;
					const pushCall = makeCall(makeIdent("msGenericArrayPush", loc), [makeHiddenAddr(accRef, loc), elemAccess], loc);
					const pushStmt = makeExprStmt(pushCall, loc);
					const iv2 = makeIdentResolved(iSym, loc);
					iv2.nodeType = int32Type();
					const iv3 = makeIdentResolved(iSym, loc);
					iv3.nodeType = int32Type();
					const incr = makeExprStmt(makeAssign(iv2, makeBinary(iv3, "+", makeNumber(1, loc), loc), loc), loc);
					items.push(makeWhile(cond, makeBlock([pushStmt, incr], loc), loc));
					const restRef = makeIdentResolved(accSym, loc);
					restRef.nodeType = restType;
					const restDecl = makeVarDecl(id.name, restRef, declKind, loc);
					restDecl.nodeType = restType;
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
					init = nullishLowered(access, def, loc, elemType);
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
				items.push(makeVarDecl(id.name, init, declKind, loc));
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
			if (p.propDefault != null) init = nullishLowered(memberAccess, p.propDefault, loc, fieldType);
			items.push(makeVarDecl(id.name, init, declKind, loc));
		}
	}
	return items;
}

function expandDestructuring(stmt: Node, ctx: TransformContext): Node[] {
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
