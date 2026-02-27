// Raiser codegen — Statement compilation
// AST statement nodes → bytecode instructions.

import {
	Node, NodeKind,
	ReturnStmtData, BlockStmtData, ExprStmtData
} from "../../ast/node";
import { RaiserOpcode, raiserABC, raiserABx } from "../../raiser/bytecode";
import { raiserNil } from "../../raiser/value";
import {
	RaiserCompState, emitInst, allocReg, emitLoadConst, emitRet
} from "./context";
import { compileExpr } from "./expressions";

// --- Statement compilation ---

export function compileStmt(s: RaiserCompState, node: Node): void {
	const k = node.kind;

	if (k === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		if (d.argument !== null) {
			const reg = compileExpr(s, d.argument);
			emitRet(s, reg);
		} else {
			const reg = allocReg(s);
			emitLoadConst(s, reg, raiserNil());
			emitRet(s, reg);
		}
		return;
	}

	if (k === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		compileExpr(s, d.expr);
		return;
	}

	if (k === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		let i = 0;
		while (i < d.statements.length) {
			compileStmt(s, d.statements[i]);
			i = i + 1;
		}
		return;
	}

	// Unsupported statement — skip
}
