// Raiser codegen — Statement compilation
// AST statement nodes → bytecode instructions.

import {
	Node, NodeKind,
	ReturnStmtData, BlockStmtData, ExprStmtData,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	ForStmtData, ForOfStmtData,
	ExportDeclData, DecoratedDeclData, ImportDeclData,
	IdentifierData
} from "../../ast/node";
import { RaiserOpcode, raiserABC, raiserAx } from "../../raiser/bytecode";
import { raiserNil, raiserInt } from "../../raiser/value";
import {
	RaiserCompState, emitInst, allocReg, addConst, emitLoadConst, emitRet,
	declareLocal, declareLocalStr,
	emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, codeLen,
	pushLoop, currentLoop, hasLoop, patchLoopBreaks,
	resolveBuiltin, registerFunc, resolveFunc, emitClosurePair
} from "./context";
import { compileExpr, exprIsString } from "./expressions";

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
		compileBlock(s, node);
		return;
	}

	if (k === NodeKind.VariableDecl) {
		compileVariableDecl(s, node);
		return;
	}

	if (k === NodeKind.IfStmt) {
		compileIfStmt(s, node);
		return;
	}

	if (k === NodeKind.WhileStmt) {
		compileWhileStmt(s, node);
		return;
	}

	if (k === NodeKind.BreakStmt) {
		if (!hasLoop(s)) return;
		const loop = currentLoop(s);
		const jumpIdx = emitJumpPlaceholder(s);
		loop.breakPatches.items.push(jumpIdx);
		return;
	}

	if (k === NodeKind.ContinueStmt) {
		if (!hasLoop(s)) return;
		const loop = currentLoop(s);
		const offset = loop.startIp - codeLen(s) - 1;
		emitInst(s, raiserAx(RaiserOpcode.Jump, offset));
		return;
	}

	if (k === NodeKind.FunctionDecl) {
		// Handled at top-level by rgen.ms two-phase compilation
		return;
	}

	if (k === NodeKind.DoWhileStmt) {
		compileDoWhileStmt(s, node);
		return;
	}

	if (k === NodeKind.ForStmt) {
		compileForStmt(s, node);
		return;
	}

	if (k === NodeKind.ForOfStmt) {
		compileForOfStmt(s, node);
		return;
	}

	if (k === NodeKind.ImportDecl) {
		compileImportDecl(s, node);
		return;
	}

	if (k === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		// export default expr → compile as expression and halt with result
		if (d.exportedDecl.kind === NodeKind.ExprStmt) {
			const ed = d.exportedDecl.data as ExprStmtData;
			const reg = compileExpr(s, ed.expr);
			emitInst(s, raiserABC(RaiserOpcode.Halt, reg, 0, 0));
			return;
		}
		compileStmt(s, d.exportedDecl);
		return;
	}

	if (k === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		compileStmt(s, d.decoratedNode);
		return;
	}

	if (k === NodeKind.EnumDecl || k === NodeKind.InterfaceDecl || k === NodeKind.TypeAliasDecl || k === NodeKind.ClassDecl) {
		// Enums/classes are collected in Phase 1 by rgen.ms; interfaces/types are compile-time only
		return;
	}

	// Unsupported statement — skip
}

// --- Block ---

function compileBlock(s: RaiserCompState, node: Node): void {
	const d = node.data as BlockStmtData;
	const savedLocals = s.locals.items.length;
	for (let i = 0; i < d.statements.length; i = i + 1) {
		compileStmt(s, d.statements[i]);
	}
	// Restore locals scope — drop block-scoped vars
	s.locals.items.length = savedLocals;
}

// --- Variable Declaration ---

function compileVariableDecl(s: RaiserCompState, node: Node): void {
	const d = node.data as VariableDeclData;
	if (d.initializer !== null) {
		// Check if initializer is a function reference (e.g., from non-capturing lambda lifting)
		// Wrap in closure pair { fn: funcIdx, env: nil } so it can be passed around and called uniformly
		if (d.initializer.kind === NodeKind.Identifier) {
			const initId = d.initializer.data as IdentifierData;
			const fIdx = resolveFunc(s, initId.name);
			if (fIdx >= 0) {
				const pairReg = emitClosurePair(s, fIdx, -1);
				declareLocal(s, d.declName, pairReg);
				return;
			}
		}
		const isStr = exprIsString(s, d.initializer);
		const reg = compileExpr(s, d.initializer);
		declareLocalStr(s, d.declName, reg, isStr);
	} else {
		const reg = allocReg(s);
		emitLoadConst(s, reg, raiserNil());
		declareLocal(s, d.declName, reg);
	}
}

// --- If Statement ---

function compileIfStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as IfStmtData;
	const condReg = compileExpr(s, d.condition);
	const jumpToElse = emitBranchIfFalsy(s, condReg);

	compileStmt(s, d.consequent);

	if (d.alternate !== null) {
		const jumpPastElse = emitJumpPlaceholder(s);
		patchJumpTo(s, jumpToElse, codeLen(s));
		compileStmt(s, d.alternate);
		patchJumpTo(s, jumpPastElse, codeLen(s));
	} else {
		patchJumpTo(s, jumpToElse, codeLen(s));
	}
}

// --- Do-While Statement ---

function compileDoWhileStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as DoWhileStmtData;
	const loopStart = codeLen(s);
	pushLoop(s, loopStart);

	compileStmt(s, d.doBody);

	// Condition at the end — loop back if truthy
	const condReg = compileExpr(s, d.doCondition);
	const exitJump = emitBranchIfFalsy(s, condReg);
	const backOffset = loopStart - codeLen(s) - 1;
	emitInst(s, raiserAx(RaiserOpcode.Jump, backOffset));

	patchJumpTo(s, exitJump, codeLen(s));
	patchLoopBreaks(s);
}

// --- While Statement ---

function compileWhileStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as WhileStmtData;
	const loopStart = codeLen(s);
	pushLoop(s, loopStart);

	const condReg = compileExpr(s, d.whileCondition);
	const exitJump = emitBranchIfFalsy(s, condReg);

	compileStmt(s, d.whileBody);

	// Jump back to loop start
	const backOffset = loopStart - codeLen(s) - 1;
	emitInst(s, raiserAx(RaiserOpcode.Jump, backOffset));

	// Patch exit + break jumps
	patchJumpTo(s, exitJump, codeLen(s));
	patchLoopBreaks(s);
}

// --- For Statement ---
// for (init; cond; update) body → init; while (cond) { body; update; }

function compileForStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as ForStmtData;

	// Compile init
	if (d.forInit !== null) {
		compileStmt(s, d.forInit);
	}

	const loopStart = codeLen(s);
	pushLoop(s, loopStart);

	// Condition
	let exitJump = -1;
	if (d.forCondition !== null) {
		const condReg = compileExpr(s, d.forCondition);
		exitJump = emitBranchIfFalsy(s, condReg);
	}

	// Body
	compileStmt(s, d.forBody);

	// Update
	if (d.forUpdate !== null) {
		compileExpr(s, d.forUpdate);
	}

	// Jump back to condition
	const backOffset = loopStart - codeLen(s) - 1;
	emitInst(s, raiserAx(RaiserOpcode.Jump, backOffset));

	// Patch exit + break jumps
	if (exitJump >= 0) {
		patchJumpTo(s, exitJump, codeLen(s));
	}
	patchLoopBreaks(s);
}

// --- For-Of Statement ---
// for (const x of arr) body → let __i = 0; while (__i < arr.length) { x = arr[__i]; body; __i++; }

function compileForOfStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as ForOfStmtData;

	// Compile iterable (array)
	const arrReg = compileExpr(s, d.forOfIterable);

	// Hidden index: __i = 0
	const idxReg = allocReg(s);
	emitLoadConst(s, idxReg, raiserInt(0));

	// Length register (recomputed each iteration)
	const lenReg = allocReg(s);

	// Element register — declared as a local for the binding name
	const elemReg = allocReg(s);
	declareLocal(s, d.forOfBinding, elemReg);

	const loopStart = codeLen(s);
	pushLoop(s, loopStart);

	// Condition: if idx < len, skip past the exit jump (continue loop)
	emitInst(s, raiserABC(RaiserOpcode.ArrayLen, lenReg, arrReg, 0));
	emitInst(s, raiserABC(RaiserOpcode.BltI64, idxReg, lenReg, 1));
	const exitJump = emitJumpPlaceholder(s);

	// Load element: elem = arr[idx]
	emitInst(s, raiserABC(RaiserOpcode.LoadIndex, elemReg, arrReg, idxReg));

	// Body
	compileStmt(s, d.forOfBody);

	// Increment index: __i++
	const oneReg = allocReg(s);
	emitLoadConst(s, oneReg, raiserInt(1));
	emitInst(s, raiserABC(RaiserOpcode.AddI64, idxReg, idxReg, oneReg));

	// Jump back
	const backOffset = loopStart - codeLen(s) - 1;
	emitInst(s, raiserAx(RaiserOpcode.Jump, backOffset));

	// Patch exit + break
	patchJumpTo(s, exitJump, codeLen(s));
	patchLoopBreaks(s);
}

// --- Import Declaration ---
// Binds imported names from builtin modules as local variables.
// Each imported name is resolved from the builtin registry and bound
// as a local holding the function index (for later Call resolution).

function compileImportDecl(s: RaiserCompState, node: Node): void {
	const d = node.data as ImportDeclData;
	// Bind each imported name — check if it's a registered builtin
	for (let i = 0; i < d.importNames.length; i = i + 1) {
		const name = d.importNames[i];
		const funcIdx = resolveBuiltin(s, name);
		if (funcIdx >= 0) {
			// Builtin found — register as a named function for direct calls
			registerFunc(s, name, funcIdx);
		}
		// Unknown imports are silently skipped
	}
}
