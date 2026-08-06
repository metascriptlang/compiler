// Destructuring Lowering — transforms DestructuringDecl → temp var + field access

import {
	Node, NodeKind, DeclKind, SourceLocation, Type, TypeKind,
	DestructuringDeclData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData, IdentifierData,
} from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { noneType } from "../../checker/types";
import { walkExpandBlocks } from "../walker";
import { makeIdentResolved, makeVarDecl, makeNumber, makeArrayAccess, makeMember, makeCall, boolToDeclKind } from "../util";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerDestructuring(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandDestructuring, ctx);
	return program;
}

// Element type at index `i` of a destructured base (tuple → per-index, array → element) —
// mirrors the checker's own derivation (defineForOfPatternBindings). Carried onto the
// synthetic index access so a later capture (lambda lifting) types the env field concretely;
// without it a destructured closure element defaults to `double`/void* in the captured env.
function destrElemType(base: Node, i: number): Type {
	let bt = base.nodeType;
	if (bt === null) return null as unknown as Type;
	if (bt.kind === TypeKind.Ref && bt.typeReturn !== null) bt = bt.typeReturn;
	if (bt.kind === TypeKind.Tuple && i < bt.typeChildren.length) return bt.typeChildren[i];
	if (bt.kind === TypeKind.Array && bt.typeReturn !== null) return bt.typeReturn;
	return null as unknown as Type;
}

// Expand array pattern [a, b, ...rest] → indexed access
function expandArrayRet(
	pattern: Node, base: Node, declKind: DeclKind,
	loc: SourceLocation, ctx: TransformContext
): Node[] {
	const apd = pattern.data as ArrayPatternData;
	const items: Node[] = [];
	for (let i = 0; i < apd.patternElements.length; i += 1) {
		const elem = apd.patternElements[i];

		// Rest element: last + hasRestElement
		if (apd.hasRestElement && i === apd.patternElements.length - 1) {
			if (elem.kind === NodeKind.Identifier) {
				const id = elem.data as IdentifierData;
				const sliceCallee = makeMember(base, "slice", loc);
				const sliceArg = makeNumber(i, loc);
				const sliceCall = makeCall(sliceCallee, [sliceArg], loc);
				items.push(makeVarDecl(id.name, sliceCall, declKind, loc));
			}
			continue;
		}

		// Simple identifier binding
		if (elem.kind === NodeKind.Identifier) {
			const id = elem.data as IdentifierData;
			if (id.name !== "_") {
				const access = makeArrayAccess(base, makeNumber(i, loc), loc);
				const elemType = destrElemType(base, i);
				if (elemType !== null) access.nodeType = elemType;
				items.push(makeVarDecl(id.name, access, declKind, loc));
			}
		}
	}
	return items;
}

// Expand object pattern {x, y: z} → member access
function expandObjectRet(
	pattern: Node, base: Node, declKind: DeclKind,
	loc: SourceLocation, ctx: TransformContext
): Node[] {
	const opd = pattern.data as ObjectPatternData;
	const items: Node[] = [];
	for (const prop of opd.patternProps) {
		if (prop.kind !== NodeKind.ObjectPatternProp) continue;
		const p = prop.data as ObjectPatternPropData;
		if (p.propAlias.kind === NodeKind.Identifier) {
			const id = p.propAlias.data as IdentifierData;
			const memberAccess = makeMember(base, p.propKey, loc);
			items.push(makeVarDecl(id.name, memberAccess, declKind, loc));
		}
	}
	return items;
}

function expandDestructuring(stmt: Node, ctx: TransformContext): Node[] {
	if (stmt.kind !== NodeKind.DestructuringDecl) return [stmt];
	const d = stmt.data as DestructuringDeclData;
	const loc = stmt.location;
	const result: Node[] = [];

	// Simple RHS (identifier/member/access) → skip temp
	let baseExpr: Node = null as unknown as Node;
	const initKind = d.destrInit.kind;
	if (initKind === NodeKind.Identifier || initKind === NodeKind.MemberExpr || initKind === NodeKind.ArrayAccess) {
		baseExpr = d.destrInit;
	} else {
		const sym = freshTempSym(ctx, "destr", d.destrInit.nodeType !== null ? d.destrInit.nodeType : noneType());
		const tempDecl = makeVarDecl(sym.name, d.destrInit, DeclKind.Const, loc);
		tempDecl.resolvedSym = sym;
		// Propagate type so nativeLower can rewrite tuple access (t[0] → t._0)
		if (d.destrInit.nodeType !== null) {
			tempDecl.nodeType = d.destrInit.nodeType;
		}
		result.push(tempDecl);
		baseExpr = makeIdentResolved(sym, loc);
	}

	const dk = boolToDeclKind(d.destrIsConst);
	if (d.destrPattern.kind === NodeKind.ArrayPattern) {
		const expanded = expandArrayRet(d.destrPattern, baseExpr, dk, loc, ctx);
		for (const node of expanded) {
			result.push(node);
		}
	}
	if (d.destrPattern.kind === NodeKind.ObjectPattern) {
		const expanded = expandObjectRet(d.destrPattern, baseExpr, dk, loc, ctx);
		for (const node of expanded) {
			result.push(node);
		}
	}

	return result;
}

// ===== Tests =====
test "array 2 elements" { assert stmtCountAfter("const [a, b] = f();", lowerDestructuring) === 3; }

test "first stmt is temp VarDecl" { assert firstStmtKindAfter("const [a, b] = f();", lowerDestructuring) === NodeKind.VariableDecl; }

test "object destructuring" { assert stmtCountAfter("const { x, y } = f();", lowerDestructuring) === 3; }

test "simple RHS skips temp" { assert stmtCountAfter("const [a, b] = myVar;", lowerDestructuring) === 2; }

test "non-destructuring passthrough" { assert stmtCountAfter("const x = 1;", lowerDestructuring) === 1; }

test "preserves surrounding stmts" { assert stmtCountAfter("let z = 0; const [a, b] = f(); let w = 1;", lowerDestructuring) === 5; }
