// Void bind lowering — a bound void result materializes its null carrier.
// `const n = f()` (f(): void) becomes `f(); const n = null;`, the binding's
// symbol is retyped to null (C repr: void*), and surviving void-stamped
// identifier uses are restamped, so no `void` local, array element, or async
// env field ever reaches the emitters. The checker has already applied the
// TS-strict refusals by the time this runs.

import { Node, NodeKind, TypeKind, VariableDeclData, BinaryExprData, ExprStmtData, BlockStmtData, ProgramData } from "../../ast/node";
import { nullType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode, walkBlockExpanding } from "../walker";
import { makeNull, makeExprStmt } from "../util";

export function lowerVoidBind(program: Node, ctx: TransformContext): Node {
	walkNode(program, expandVoidBinds);
	walkNode(program, restampVoidUse);
	return program;
}

function expandVoidBinds(node: Node): Node {
	if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		d.statements = walkBlockExpanding(d.statements, rewriteStmt);
	} else if (node.kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		d.programStmts = walkBlockExpanding(d.programStmts, rewriteStmt);
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

function rewriteStmt(stmt: Node): Node[] {
	if (stmt.kind === NodeKind.VariableDecl) {
		const d = stmt.data as VariableDeclData;
		if (d.initializer !== null && isVoidTyped(d.initializer)) {
			const init = d.initializer;
			d.initializer = makeNull(stmt.location);
			retypeDeclSymbol(stmt);
			if (isEffectFree(init)) return [stmt];
			return [makeExprStmt(init, init.location), stmt];
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
	return node;
}
