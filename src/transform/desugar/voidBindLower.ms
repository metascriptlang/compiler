// Void bind lowering — a bound void result materializes its null carrier.
// `const n = f()` (f(): void) becomes `f(); const n = null;`, the binding's
// symbol is retyped to null (C repr: void*), and surviving void-stamped
// identifier uses are restamped, so no `void` local, array element, or async
// env field ever reaches the emitters. The checker has already applied the
// TS-strict refusals by the time this runs.

import { Node, NodeKind, Type, TypeKind, DeclKind, VariableDeclData, BinaryExprData, ExprStmtData, BlockStmtData, ProgramData, ArrayLiteralData, ObjectLiteralData } from "../../ast/node";
import { nullType, createArray, createRef } from "../../checker/types";
import { TransformContext, freshOwnedSym } from "../context";
import { walkNode, walkBlockExpanding } from "../walker";
import { makeNull, makeExprStmt, makeVarDecl, makeIdentResolved } from "../util";

export function lowerVoidBind(program: Node, ctx: TransformContext): Node {
	walkNode(program, (n: Node): Node => expandVoidBinds(n, ctx));
	walkNode(program, restampVoidUse);
	return program;
}

function expandVoidBinds(node: Node, ctx: TransformContext): Node {
	if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		d.statements = walkBlockExpanding(d.statements, (s: Node): Node[] => rewriteStmt(s, ctx));
	} else if (node.kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		d.programStmts = walkBlockExpanding(d.programStmts, (s: Node): Node[] => rewriteStmt(s, ctx));
	}
	return node;
}

function isVoidTyped(n: Node): boolean {
	return n !== null && n.nodeType !== null && n.nodeType.kind === TypeKind.Void;
}

function isEffectFree(n: Node): boolean {
	return n.kind === NodeKind.Identifier || n.kind === NodeKind.NullLiteral;
}

function retypeDeclSymbol(decl: Node): void {
	if (decl.resolvedSym !== null && decl.resolvedSym.symbolType !== null
		&& decl.resolvedSym.symbolType.kind === TypeKind.Void) {
		decl.resolvedSym.symbolType = nullType();
	}
	if (decl.nodeType !== null && decl.nodeType.kind === TypeKind.Void) {
		decl.nodeType = nullType();
	}
}

// An array slot holding a void call has no value to store: the call runs as its own
// statement and the slot keeps the null carrier. Effectful siblings ahead of the last
// void slot move to temps, so hoisting cannot reorder evaluation.
function materializeVoidSlots(expr: Node, ctx: TransformContext): Node[] {
	const pre: Node[] = [];
	if (expr === null) return pre;
	if (expr.kind === NodeKind.ArrayLiteral) {
		const d = expr.data as ArrayLiteralData;
		const voidCount = materializeSlotList(d.elements, pre, ctx);
		if (voidCount > 0 && voidCount === d.elements.length) {
			const nt = withNullElement(expr.nodeType);
			if (nt !== null) expr.nodeType = nt;
		}
		return pre;
	}
	if (expr.kind === NodeKind.ObjectLiteral) {
		const d = expr.data as ObjectLiteralData;
		const voidCount = materializeSlotList(d.properties, pre, ctx);
		// The literal's struct type is the binding's own type object, so retyping the
		// void fields in place reaches the declaration too.
		if (voidCount > 0) {
			const t = expr.nodeType;
			if (t !== null && t.typeChildren !== null) {
				for (let i = 0; i < t.typeChildren.length; i += 1) {
					if (t.typeChildren[i] !== null && t.typeChildren[i].kind === TypeKind.Void) {
						t.typeChildren[i] = nullType();
					}
				}
			}
		}
		return pre;
	}
	return pre;
}

function materializeSlotList(items: Node[], pre: Node[], ctx: TransformContext): int32 {
	let lastVoid = -1;
	let voidCount = 0;
	for (let i = 0; i < items.length; i += 1) {
		if (isVoidTyped(items[i])) { lastVoid = i; voidCount = voidCount + 1; }
	}
	if (lastVoid < 0) return 0;
	for (let i = 0; i <= lastVoid; i += 1) {
		const it = items[i];
		if (isVoidTyped(it)) {
			if (!isEffectFree(it)) pre.push(makeExprStmt(it, it.location));
			const carrier = makeNull(it.location);
			carrier.nodeType = nullType();
			items[i] = carrier;
		} else if (!isEffectFree(it)) {
			const sym = freshOwnedSym(ctx, "voidslot", it.nodeType);
			const decl = makeVarDecl(sym.name, it, DeclKind.Const, it.location);
			decl.nodeType = it.nodeType;
			decl.resolvedSym = sym;
			pre.push(decl);
			items[i] = makeIdentResolved(sym, it.location);
		}
	}
	return voidCount;
}

// Element retype only — the Ref wrapper decides the C repr, so rebuilding the array
// type without it turns a pointer local into a by-value one.
function withNullElement(t: Type | null): Type | null {
	if (t === null) return null;
	if (t.kind === TypeKind.Array) return createArray(nullType());
	if (t.kind === TypeKind.Ref && t.typeReturn !== null && t.typeReturn.kind === TypeKind.Array) {
		return createRef(createArray(nullType()));
	}
	return null;
}

function rewriteStmt(stmt: Node, ctx: TransformContext): Node[] {
	if (stmt.kind === NodeKind.VariableDecl) {
		const d = stmt.data as VariableDeclData;
		if (d.initializer !== null && isVoidTyped(d.initializer)) {
			const init = d.initializer;
			d.initializer = makeNull(stmt.location);
			retypeDeclSymbol(stmt);
			if (isEffectFree(init)) return [stmt];
			return [makeExprStmt(init, init.location), stmt];
		}
		if (d.initializer !== null) {
			const pre = materializeVoidSlots(d.initializer, ctx);
			if (pre.length > 0) {
				const nt = withNullElement(stmt.nodeType);
				if (nt !== null) stmt.nodeType = nt;
				if (stmt.resolvedSym !== null) {
					const st = withNullElement(stmt.resolvedSym.symbolType);
					if (st !== null) stmt.resolvedSym.symbolType = st;
				}
				pre.push(stmt);
				return pre;
			}
		}
		return [stmt];
	}
	if (stmt.kind === NodeKind.ExprStmt) {
		const ed = stmt.data as ExprStmtData;
		const e = ed.expr;
		if (e !== null && e.kind === NodeKind.BinaryExpr) {
			const bd = e.data as BinaryExprData;
			if (bd.operator === "=" && isVoidTyped(bd.right)) {
				const rhs = bd.right;
				bd.right = makeNull(stmt.location);
				if (isEffectFree(rhs)) return [stmt];
				return [makeExprStmt(rhs, rhs.location), stmt];
			}
			if (bd.operator === "=") {
				const pre = materializeVoidSlots(bd.right, ctx);
				if (pre.length > 0) { pre.push(stmt); return pre; }
			}
		}
	}
	return [stmt];
}

function restampVoidUse(node: Node): Node {
	if (node.kind === NodeKind.Identifier && node.nodeType !== null
		&& node.nodeType.kind === TypeKind.Void
		&& node.resolvedSym !== null && node.resolvedSym.symbolType !== null
		&& node.resolvedSym.symbolType.kind === TypeKind.Null) {
		node.nodeType = nullType();
	}
	// Every void bind and slot has been materialized by now, so a surviving void-typed
	// element read is a carrier read — leaving the stamp makes it stringify as <object>.
	if ((node.kind === NodeKind.ArrayAccess || node.kind === NodeKind.MemberExpr)
		&& node.nodeType !== null && node.nodeType.kind === TypeKind.Void) {
		node.nodeType = nullType();
	}
	return node;
}
