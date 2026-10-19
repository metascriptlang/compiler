// Raiser codegen — Statement compilation
// AST statement nodes → bytecode instructions.

import {
	Node, NodeKind,
	ReturnStmtData, BlockStmtData, ExprStmtData, MacroInvocationData, UnreachableStmtData,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	ForStmtData, ForOfStmtData, BreakStmtData, ContinueStmtData,
	ExportDeclData, DecoratedDeclData,
	SwitchStmtData, SwitchCaseData,
	TryCatchStmtData, ThrowStmtData,
} from "../../ast/node";
import { RaiserOpcode, raiserABC, raiserAx } from "../../raiser/bytecode";
import { raiserNil, raiserInt, raiserConstString } from "../../raiser/value";
import {
	RaiserCompState, emitInst, allocReg, emitLoadConst, emitRet,
	declareLocal, declaredSymbol, regIsFixedLocal,
	emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, patchJumpsTo, codeLen,
	emitAbxPlaceholder, patchAbxTo,
	pushLoop, jumpTarget, patchLoopBreaks, patchLoopContinues, queueRaiserCompileError, emitTrapNil,
	emitClosurePair,
	registerRaiserStmtCompiler, resolveGlobal, resolveStaticInitGuard, resolveRoutine, addConst,
} from "./context";
import { compileExpr, compileExprForEffect, condJumps, exprIsString } from "./expressions";
import { emitValueCopy, emitZeroValue } from "./valueCopy";

// --- Statement compilation ---

export function compileStmt(s: RaiserCompState, node: Node): void {
	match (node.kind) {
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (d.argument != null) {
				const reg = emitValueCopy(s, compileExpr(s, d.argument), d.argument.nodeType);
				emitRet(s, reg);
			} else {
				const reg = allocReg(s);
				emitLoadConst(s, reg, raiserNil());
				emitRet(s, reg);
			}
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			if (d.expr.kind == NodeKind.MacroInvocation) {
				const mi = d.expr.data as MacroInvocationData;
				if (mi.macroName != "emit") { return; }
			}
			compileExprForEffect(s, d.expr);
		},
		NodeKind.BlockStmt => { compileBlock(s, node); },
		NodeKind.VariableDecl => { compileVariableDecl(s, node); },
		NodeKind.IfStmt => { compileIfStmt(s, node); },
		NodeKind.WhileStmt => { compileWhileStmt(s, node); },
		NodeKind.BreakStmt => {
			const label = (node.data as BreakStmtData).breakLabel;
			const loop = jumpTarget(s, label);
			if (loop != null) {
				leaveTries(s, loop.tryDepth);
				loop.breakPatches.items.push(emitJumpPlaceholder(s));
			} else if (label != "") trapMissingTarget(s, node, `break ${label}`);
		},
		NodeKind.ContinueStmt => {
			const label = (node.data as ContinueStmtData).continueLabel;
			const loop = jumpTarget(s, label);
			if (loop != null) {
				leaveTries(s, loop.tryDepth);
				loop.continuePatches.items.push(emitJumpPlaceholder(s));
			} else if (label != "") trapMissingTarget(s, node, `continue ${label}`);
		},
		NodeKind.FunctionDecl => {},
		NodeKind.DoWhileStmt => { compileDoWhileStmt(s, node); },
		NodeKind.ForStmt => { compileForStmt(s, node); },
		NodeKind.ForOfStmt => { compileForOfStmt(s, node); },
		NodeKind.ImportDecl => {},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			if (d.exportedDecl.kind == NodeKind.ExprStmt) {
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
		NodeKind.TryCatchStmt => { compileTryCatchStmt(s, node); },
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			const reg = compileExpr(s, d.throwArg);
			emitInst(s, raiserABC(RaiserOpcode.Throw, reg, 0, 0));
		},
		NodeKind.UnreachableStmt => {
			const d = node.data as UnreachableStmtData;
			emitTrapNil(s, d.unreachableMsg.length > 0 ? "unreachable: " + d.unreachableMsg : "unreachable");
		},
		NodeKind.EnumDecl | NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.TypeAliasDecl | NodeKind.ClassDecl => {},
		_ => {},
	};
}

registerRaiserStmtCompiler(compileStmt);

function trapMissingTarget(s: RaiserCompState, node: Node, jump: string): void {
	const msg = `cannot find the loop that '${jump}' leaves`;
	queueRaiserCompileError(msg, node.location.line, node.location.column);
	emitTrapNil(s, msg);
}

// --- Block ---

function compileBlock(s: RaiserCompState, node: Node): void {
	const d = node.data as BlockStmtData;
	const savedLocals = s.locals.items.length;
	for (const stmt of d.statements) {
		compileStmt(s, stmt);
	}
	// Restore locals scope — drop block-scoped vars
	s.locals.items.shrink(savedLocals);
}

// --- Variable Declaration ---

function compileVariableDecl(s: RaiserCompState, node: Node): void {
	const d = node.data as VariableDeclData;
	const initGuard = resolveStaticInitGuard(s, node.resolvedSym);
	if (initGuard < 0) {
		compileVariableDeclValue(s, node, d);
		return;
	}

	const guardReg = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.LoadGlobal, guardReg, initGuard, 0));
	const jumpToInit = emitBranchIfFalsy(s, guardReg);
	const jumpPastInit = emitJumpPlaceholder(s);
	patchJumpTo(s, jumpToInit, codeLen(s));
	emitLoadConst(s, guardReg, raiserInt(1));
	emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, guardReg, initGuard, 0));
	compileVariableDeclValue(s, node, d);
	patchJumpTo(s, jumpPastInit, codeLen(s));
}

function compileVariableDeclValue(s: RaiserCompState, node: Node, d: VariableDeclData): void {
	if (d.initializer != null) {
		if (d.initializer.kind == NodeKind.Identifier) {
			const fIdx = resolveRoutine(s, d.initializer.resolvedSym);
			if (fIdx >= 0) {
				const pairReg = emitClosurePair(s, fIdx, -1);
				const global = resolveGlobal(s, node.resolvedSym);
				if (global >= 0) {
					emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, pairReg, global, 0));
					return;
				}
				declareLocal(s, declaredSymbol(node, d.declName), pairReg);
				return;
			}
		}
		const isStr = exprIsString(s, d.initializer);
		const reg = emitValueCopy(s, compileExpr(s, d.initializer), node.nodeType);
		const global = resolveGlobal(s, node.resolvedSym);
		if (global >= 0) {
			emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, reg, global, 0));
			return;
		}
		if (regIsFixedLocal(s, reg)) {
			const slot = allocReg(s);
			emitInst(s, raiserABC(RaiserOpcode.Move, slot, reg, 0));
			declareLocal(s, declaredSymbol(node, d.declName), slot, isStr);
			return;
		}
		declareLocal(s, declaredSymbol(node, d.declName), reg, isStr);
	} else {
		const reg = emitZeroValue(s, node.nodeType);
		const global = resolveGlobal(s, node.resolvedSym);
		if (global >= 0) {
			emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, reg, global, 0));
			return;
		}
		declareLocal(s, declaredSymbol(node, d.declName), reg);
	}
}

// --- If Statement ---

function compileIfStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as IfStmtData;
	const toElse = condJumps(s, d.condition, false);

	compileStmt(s, d.consequent);

	const alternate = d.alternate;
	const emptyElse = alternate != null && alternate.kind == NodeKind.BlockStmt && (alternate.data as BlockStmtData).statements.length == 0;
	if (alternate != null && !emptyElse) {
		const jumpPastElse = emitJumpPlaceholder(s);
		patchJumpsTo(s, toElse, codeLen(s));
		compileStmt(s, alternate);
		patchJumpTo(s, jumpPastElse, codeLen(s));
	} else {
		patchJumpsTo(s, toElse, codeLen(s));
	}
}

// --- Do-While Statement ---

function compileDoWhileStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as DoWhileStmtData;
	const loopStart = codeLen(s);
	pushLoop(s, loopStart, d.dwLabel);

	compileStmt(s, d.doBody);

	patchLoopContinues(s);

	// Condition at the end — loop back if truthy
	patchJumpsTo(s, condJumps(s, d.doCondition, true), loopStart);
	patchLoopBreaks(s);
}

// --- While Statement ---

function compileWhileStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as WhileStmtData;
	const loopStart = codeLen(s);
	pushLoop(s, loopStart, d.whileLabel);

	const exitJumps = condJumps(s, d.whileCondition, false);

	compileStmt(s, d.whileBody);

	patchLoopContinues(s);

	// Jump back to loop start
	const backOffset = loopStart - codeLen(s) - 1;
	emitInst(s, raiserAx(RaiserOpcode.Jump, backOffset));

	// Patch exit + break jumps
	patchJumpsTo(s, exitJumps, codeLen(s));
	patchLoopBreaks(s);
}

// --- For Statement ---
// for (init; cond; update) body → init; while (cond) { body; update; }

function compileForStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as ForStmtData;

	// Compile init
	if (d.forInit != null) {
		compileStmt(s, d.forInit);
	}

	const loopStart = codeLen(s);
	pushLoop(s, loopStart, d.forLabel);

	// Condition
	let exitJumps: int32[] = [];
	if (d.forCondition != null) {
		exitJumps = condJumps(s, d.forCondition, false);
	}

	// Body
	compileStmt(s, d.forBody);

	patchLoopContinues(s);

	// Update
	if (d.forUpdate != null) {
		compileExprForEffect(s, d.forUpdate);
	}

	// Jump back to condition
	const backOffset = loopStart - codeLen(s) - 1;
	emitInst(s, raiserAx(RaiserOpcode.Jump, backOffset));

	// Patch exit + break jumps
	patchJumpsTo(s, exitJumps, codeLen(s));
	patchLoopBreaks(s);
}

// --- For-Of Statement ---
// for (const x of arr) body → let __i = 0; while (__i < arr.length) { x = arr[__i]; body; raise if arr.length changed; __i++; }

function compileForOfStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as ForOfStmtData;

	const arrReg = compileExpr(s, d.forOfIterable);
	const isString = exprIsString(s, d.forOfIterable);
	const lenOp = isString ? RaiserOpcode.StrByteLen : RaiserOpcode.ArrayLen;
	const readsLocation = isString && d.forOfIterable.kind == NodeKind.Identifier;

	// Hidden index: __i = 0
	const idxReg = allocReg(s);
	emitLoadConst(s, idxReg, raiserInt(0));

	// Length register (recomputed each iteration)
	const lenReg = allocReg(s);

	// Element register — declared as a local for the binding name
	const elemReg = allocReg(s);
	declareLocal(s, declaredSymbol(node, d.forOfBinding), elemReg);

	const loopStart = codeLen(s);
	pushLoop(s, loopStart, d.forOfLabel);

	const headReg = readsLocation ? compileExpr(s, d.forOfIterable) : arrReg;
	// Condition: if idx < len, skip past the exit jump (continue loop)
	emitInst(s, raiserABC(lenOp, lenReg, headReg, 0));
	emitInst(s, raiserABC(RaiserOpcode.BltI64, idxReg, lenReg, 1));
	const exitJump = emitJumpPlaceholder(s);

	if (isString) {
		const callReg = allocReg(s);
		allocReg(s);
		allocReg(s);
		emitInst(s, raiserABC(RaiserOpcode.Move, callReg + 1, headReg, 0));
		emitInst(s, raiserABC(RaiserOpcode.Move, callReg + 2, idxReg, 0));
		emitInst(s, raiserABC(RaiserOpcode.CallHost, callReg, addConst(s, raiserConstString("msStringByteAt")), 2));
		emitInst(s, raiserABC(RaiserOpcode.Move, elemReg, callReg, 0));
	} else {
		emitInst(s, raiserABC(RaiserOpcode.LoadIndex, elemReg, arrReg, idxReg));
	}

	// Body
	compileStmt(s, d.forOfBody);

	patchLoopContinues(s);

	const tailReg = readsLocation ? compileExpr(s, d.forOfIterable) : arrReg;
	const nowReg = allocReg(s);
	const messageReg = allocReg(s);
	emitInst(s, raiserABC(lenOp, nowReg, tailReg, 0));
	emitInst(s, raiserABC(RaiserOpcode.BeqI64, nowReg, lenReg, 2));
	emitLoadConst(s, messageReg, raiserConstString(`the length of the ${isString ? "string" : "array"} changed while iterating over it`));
	emitInst(s, raiserABC(RaiserOpcode.Throw, messageReg, 0, 0));

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

// --- Switch Statement ---
// Compiled as sequential test-and-branch (Raiser has no jump table opcode).
// Each case: compare disc with test values, if match execute body and jump past.

// try/catch/finally lays out as:
//
//   Try →EH               safepoint = the handler metadata
//   <try body>
//   Jump →FIN             nothing raised: fall into Finally, which pops it
//   EH: Catch a=<e> →FIN  never executed; the unwinder reads a and Bx
//   Try →FIN              only with a finally clause: the unwinder popped the
//   <catch body>          try's safepoint, so this one makes a raise or a
//   Jump →FIN             return leaving the catch body run the finally
//   FIN: Finally a=<r>    R[r], R[r+1] = how the finally body was entered
//   <finally body>
//   FinallyEnd a=<r>      fall through, re-raise or return, as R[r] says
//
// The Finally marker is emitted even when the source has no finally clause,
// so the normal path always has exactly one place that pops the safepoint;
// without a finally clause the catch body has no safepoint and jumps past
// FinallyEnd.
function compileTryCatchStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as TryCatchStmtData;
	const routeReg = allocReg(s);
	allocReg(s);
	const tryIdx = emitAbxPlaceholder(s, RaiserOpcode.Try);
	s.tries.push({ finallyBody: d.finallyBody, routeReg });
	compileStmt(s, d.tryBody);
	s.tries.pop();
	const toFinally = emitJumpPlaceholder(s);

	let catchIdx = -1;
	let catchEnd = -1;
	let catchGuard = -1;
	let catchReg = 0;
	if (d.hasCatchClause) {
		catchIdx = emitAbxPlaceholder(s, RaiserOpcode.Catch);
		catchReg = allocReg(s);
		if (d.finallyBody != null) {
			catchGuard = emitAbxPlaceholder(s, RaiserOpcode.Try);
			s.tries.push({ finallyBody: d.finallyBody, routeReg });
		}
		const savedLocals = s.locals.items.length;
		if (d.catchName != "") declareLocal(s, declaredSymbol(node, d.catchName), catchReg);
		if (d.catchBody != null) compileStmt(s, d.catchBody);
		s.locals.items.shrink(savedLocals);
		if (catchGuard >= 0) s.tries.pop();
		catchEnd = emitJumpPlaceholder(s);
	}

	const finIdx = codeLen(s);
	emitInst(s, raiserABC(RaiserOpcode.Finally, routeReg, 0, 0));
	if (d.hasCatchClause) {
		patchAbxTo(s, tryIdx, RaiserOpcode.Try, 0, catchIdx);
		patchAbxTo(s, catchIdx, RaiserOpcode.Catch, catchReg, finIdx);
		if (catchGuard >= 0) {
			patchAbxTo(s, catchGuard, RaiserOpcode.Try, 0, finIdx);
			patchJumpTo(s, catchEnd, finIdx);
		}
	} else {
		patchAbxTo(s, tryIdx, RaiserOpcode.Try, 0, finIdx);
	}
	patchJumpTo(s, toFinally, finIdx);
	if (d.finallyBody != null) compileStmt(s, d.finallyBody);
	emitInst(s, raiserABC(RaiserOpcode.FinallyEnd, routeReg, 0, 0));
	if (d.hasCatchClause && catchGuard < 0) patchJumpTo(s, catchEnd, codeLen(s));
}

function leaveTries(s: RaiserCompState, depth: int32): void {
	const tries = s.tries.slice(0, s.tries.length);
	for (let j = tries.length - 1; j >= depth; j = j - 1) {
		emitInst(s, raiserABC(RaiserOpcode.Finally, tries[j].routeReg, 0, 0));
		const fin = tries[j].finallyBody;
		if (fin != null) {
			s.tries.shrink(j);
			compileStmt(s, fin);
			s.tries = tries.slice(0, tries.length);
		}
	}
}

function compileSwitchStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as SwitchStmtData;
	const discReg = compileExpr(s, d.switchDisc);

	// Collect jump-to-end patches for each matched case (break equivalent)
	const endPatches: int32[] = [];
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

		if (cd.caseTests.length == 1) {
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
