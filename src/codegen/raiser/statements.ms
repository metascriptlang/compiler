// Raiser codegen — Statement compilation
// AST statement nodes → bytecode instructions.

import {
	Node, NodeKind,
	ReturnStmtData, BlockStmtData, ExprStmtData,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	ForStmtData, ForOfStmtData,
	ExportDeclData, DecoratedDeclData, ImportDeclData,
	IdentifierData, SwitchStmtData, SwitchCaseData,
} from "../../ast/node";
import { RaiserOpcode, raiserABC, raiserAx } from "../../raiser/bytecode";
import { raiserNil, raiserInt } from "../../raiser/value";
import {
	RaiserCompState, emitInst, allocReg, emitLoadConst, emitRet,
	declareLocal, declareLocalStr,
	emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, codeLen,
	pushLoop, currentLoop, hasLoop, patchLoopBreaks,
	resolveBuiltin, registerFunc, resolveFunc, emitClosurePair
} from "./context";
import { compileExpr, exprIsString } from "./expressions";

// --- Statement compilation ---

export function compileStmt(s: RaiserCompState, node: Node): void {
	match (node.kind) {
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (d.argument !== null) {
				const reg = compileExpr(s, d.argument);
				emitRet(s, reg);
			} else {
				const reg = allocReg(s);
				emitLoadConst(s, reg, raiserNil());
				emitRet(s, reg);
			}
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			compileExpr(s, d.expr);
		},
		NodeKind.BlockStmt => { compileBlock(s, node); },
		NodeKind.VariableDecl => { compileVariableDecl(s, node); },
		NodeKind.IfStmt => { compileIfStmt(s, node); },
		NodeKind.WhileStmt => { compileWhileStmt(s, node); },
		NodeKind.BreakStmt => {
			if (hasLoop(s)) {
				const loop = currentLoop(s);
				const jumpIdx = emitJumpPlaceholder(s);
				loop.breakPatches.items.push(jumpIdx);
			}
		},
		NodeKind.ContinueStmt => {
			if (hasLoop(s)) {
				const loop = currentLoop(s);
				const offset = loop.startIp - codeLen(s) - 1;
				emitInst(s, raiserAx(RaiserOpcode.Jump, offset));
			}
		},
		NodeKind.FunctionDecl => {},
		NodeKind.DoWhileStmt => { compileDoWhileStmt(s, node); },
		NodeKind.ForStmt => { compileForStmt(s, node); },
		NodeKind.ForOfStmt => { compileForOfStmt(s, node); },
		NodeKind.ImportDecl => { compileImportDecl(s, node); },
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			if (d.exportedDecl.kind === NodeKind.ExprStmt) {
				const ed = d.exportedDecl.data as ExprStmtData;
				const reg = compileExpr(s, ed.expr);
				emitInst(s, raiserABC(RaiserOpcode.Halt, reg, 0, 0));
			} else {
				compileStmt(s, d.exportedDecl);
			}
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			compileStmt(s, d.decoratedNode);
		},
		NodeKind.SwitchStmt => { compileSwitchStmt(s, node); },
		NodeKind.EnumDecl | NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.TypeAliasDecl | NodeKind.ClassDecl => {},
		_ => {},
	};
}

// --- Block ---

function compileBlock(s: RaiserCompState, node: Node): void {
	const d = node.data as BlockStmtData;
	const savedLocals = s.locals.items.length;
	for (const stmt of d.statements) {
		compileStmt(s, stmt);
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
	for (const name of d.importNames) {
		const funcIdx = resolveBuiltin(s, name);
		if (funcIdx >= 0) {
			// Builtin found — register as a named function for direct calls
			registerFunc(s, name, funcIdx);
		}
		// Unknown imports are silently skipped
	}
}

// --- Switch Statement ---
// Compiled as sequential test-and-branch (Raiser has no jump table opcode).
// Each case: compare disc with test values, if match execute body and jump past.

function compileSwitchStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as SwitchStmtData;
	const discReg = compileExpr(s, d.switchDisc);

	// Collect jump-to-end patches for each matched case (break equivalent)
	const endPatches: number[] = [];
	let defaultCaseIdx = -1;

	// First pass: find default case index
	for (let ci = 0; ci < d.switchCases.length; ci += 1) {
		const cd = d.switchCases[ci].data as SwitchCaseData;
		if (cd.isDefault) { defaultCaseIdx = ci; }
	}

	// Compile non-default cases as sequential test-and-branch.
	// Each case: test all values → if any match, execute body once and jump to end.
	for (let ci = 0; ci < d.switchCases.length; ci += 1) {
		const cd = d.switchCases[ci].data as SwitchCaseData;
		if (cd.isDefault) continue;

		if (cd.caseTests.length === 1) {
			// Single test (common case — fast path)
			const testReg = compileExpr(s, cd.caseTests[0]);
			emitInst(s, raiserABC(RaiserOpcode.BeqI64, discReg, testReg, 1));
			const skipJump = emitJumpPlaceholder(s);
			for (const stmt of cd.caseStmts) { compileStmt(s, stmt); }
			endPatches.push(emitJumpPlaceholder(s));
			patchJumpTo(s, skipJump, codeLen(s));
		} else {
			// Multiple tests (or-pattern): check each, any match → body
			// Use a matched flag register
			const flagReg = allocReg(s);
			emitLoadConst(s, flagReg, raiserInt(0));
			for (const test of cd.caseTests) {
				const testReg = compileExpr(s, test);
				// If disc == test, set flag = 1
				emitInst(s, raiserABC(RaiserOpcode.BeqI64, discReg, testReg, 1));
				const skipSet = emitJumpPlaceholder(s);
				emitLoadConst(s, flagReg, raiserInt(1));
				patchJumpTo(s, skipSet, codeLen(s));
			}
			// If flag == 0, skip body
			const zeroReg = allocReg(s);
			emitLoadConst(s, zeroReg, raiserInt(0));
			emitInst(s, raiserABC(RaiserOpcode.BneI64, flagReg, zeroReg, 1));
			const skipBody = emitJumpPlaceholder(s);
			for (const stmt of cd.caseStmts) { compileStmt(s, stmt); }
			endPatches.push(emitJumpPlaceholder(s));
			patchJumpTo(s, skipBody, codeLen(s));
		}
	}

	// Default case
	if (defaultCaseIdx >= 0) {
		const dd = d.switchCases[defaultCaseIdx].data as SwitchCaseData;
		for (const stmt of dd.caseStmts) { compileStmt(s, stmt); }
	}

	// Patch all end jumps to here
	for (const patch of endPatches) {
		patchJumpTo(s, patch, codeLen(s));
	}
}
