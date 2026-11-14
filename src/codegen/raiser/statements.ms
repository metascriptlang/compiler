// Raiser codegen — Statement compilation
// AST statement nodes → bytecode instructions.

import {
	Node, NodeKind, NodeFlag, TypeKind, DeclKind, Symbol, SymbolFlag, SymbolKind,
	BinaryExprData, UnaryExprData, UpdateExprData, MemberExprData, ArrayAccessData, HiddenStdConvData, HiddenDerefData, NumberLiteralData, CallExprData, OutExprData,
	ReturnStmtData, BlockStmtData, ExprStmtData, MacroInvocationData, UnreachableStmtData, ConditionalExprData,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	ForStmtData, ForOfStmtData, BreakStmtData, ContinueStmtData,
	ExportDeclData, DecoratedDeclData,
	SwitchStmtData, SwitchCaseData,
	TryCatchStmtData, ThrowStmtData,
} from "../../ast/node";
import { RaiserOpcode, RaiserRegClass, RaiserRole, RaiserInstruction, raiserABC, raiserAx, immValue, branchField, branchOffset, isBranchI64, getBx, getSignedAx, opRole, opHasSite, siteArgCount, immField, FINALLY_LEAVE } from "../../raiser/bytecode";
import { raiserNil, raiserInt, raiserConstString, RaiserValueKind } from "../../raiser/value";
import {
	RaiserCompState, RaiserTryInfo, emitInst, allocReg, allocBlock, allocWord, allocRef, allocDyn, classOfReg, emitLoadConst, emitRet, emitReturnNothing,
	declareLocal, declaredSymbol, regIsFixedLocal, resetTemps, resolveLocal,
	emitBranchIfFalsy, emitJumpPlaceholder, patchJumpTo, patchJumpsTo, codeLen,
	emitAbxPlaceholder, patchAbxTo,
	pushLoop, jumpTarget, currentLoop, landsPast, patchLoopBreaks, patchLoopContinues, queueRaiserCompileError, emitTrapNil,
	emitClosurePair,
	registerRaiserStmtCompiler, resolveGlobal, resolveStaticInitGuard, resolveRoutine, addConst, isScalarClass,
} from "./context";
import { compilePackedExpr, notePackedMove, compileExpr, compileExprForEffect, condJumps, exprIsString, isAssignOp, isStrIndexReadCall } from "./expressions";
import { forEachChild } from "../../ast/visitor";
import { markBoundedCounterStep } from "../../transform/util";
import { compileOwnershipStmt } from "./drcLower";
import { allocPackedValue } from "./packedValues";
import { packedSlotShapeOf } from "./valueCopy";
import { emitZeroValue, regClassOf, allocFor, zeroIsNil } from "./valueCopy";
import { isPlainFunctionPointer, skipModifier } from "../../checker/types";
import { hasFlag } from "../../checker/symbol";

// --- Statement compilation ---

function producesNoValue(node: Node): boolean {
	if (node.kind != NodeKind.ConditionalExpr) return false;
	const d = node.data as ConditionalExprData;
	return isVoidArm(d.ternaryConsequent) || isVoidArm(d.ternaryAlternate);
}

function isVoidArm(arm: Node): boolean {
	return (arm.nodeType != null && arm.nodeType.kind == TypeKind.Void) || producesNoValue(arm);
}

export function compileStmt(s: RaiserCompState, node: Node): void {
	match (node.kind) {
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (d.argument != null && producesNoValue(d.argument)) {
				compileExprForEffect(s, d.argument);
				leaveTries(s, 0);
				emitReturnNothing(s);
			} else if (d.argument != null) {
				if (s.resultShape != null && s.resultShape.block) {
					const base = compilePackedExpr(s, d.argument, s.resultType!).base;
					leaveTries(s, 0);
					emitRet(s, base, s.resultShape);
				} else {
					const value = compileExpr(s, d.argument);
					leaveTries(s, 0);
					emitRet(s, value);
				}
			} else {
				leaveTries(s, 0);
				emitReturnNothing(s);
			}
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			if (d.expr.kind == NodeKind.MacroInvocation) {
				const mi = d.expr.data as MacroInvocationData;
				if (mi.macroName != "emit") { return; }
			}
			if (compileOwnershipStmt(s, d.expr)) return;
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
				if (s.defaultResult < 0) emitInst(s, raiserABC(RaiserOpcode.Halt, reg, 0, 0));
				else {
					if (classOfReg(s, reg) == RaiserRegClass.Ref) emitInst(s, raiserABC(RaiserOpcode.RcInc, reg, 0, 0));
					emitInst(s, raiserABC(RaiserOpcode.Move, s.defaultResult, reg, 0));
				}
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
	const enclosingRegs = s.nextReg;
	for (let i = 0; i < d.statements.length; i += 1) {
		const stmt = d.statements[i];
		if (stmt.kind == NodeKind.VariableDecl && i + 1 < d.statements.length && d.statements[i + 1].kind == NodeKind.WhileStmt) {
			markWhileCounterStep(s, stmt, d.statements[i + 1]);
		}
		compileStmt(s, stmt);
		resetTemps(s, enclosingRegs);
	}
	// Restore locals scope — drop block-scoped vars
	s.locals.items.shrink(savedLocals);
}

function compileStatements(s: RaiserCompState, statements: Node[]): void {
	const enclosingRegs = s.nextReg;
	for (const stmt of statements) {
		compileStmt(s, stmt);
		resetTemps(s, enclosingRegs);
	}
}

// --- Variable Declaration ---

function compileVariableDecl(s: RaiserCompState, node: Node): void {
	const d = node.data as VariableDeclData;
	const initGuard = resolveStaticInitGuard(s, node.resolvedSym);
	if (initGuard < 0) {
		compileVariableDeclValue(s, node, d);
		return;
	}

	const guardReg = allocDyn(s);
	emitInst(s, raiserABC(RaiserOpcode.LoadGlobal, guardReg, initGuard, 0));
	const jumpToInit = emitBranchIfFalsy(s, guardReg);
	const jumpPastInit = emitJumpPlaceholder(s);
	patchJumpTo(s, jumpToInit, codeLen(s));
	emitLoadConst(s, guardReg, raiserInt(1));
	emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, guardReg, initGuard, 0));
	compileVariableDeclValue(s, node, d);
	patchJumpTo(s, jumpPastInit, codeLen(s));
}

function takesGlobalCell(s: RaiserCompState, init: Node | null): boolean {
	if (init == null || init.kind != NodeKind.HiddenDeref) return false;
	const held = (init.data as HiddenDerefData).expr;
	return held.kind == NodeKind.Identifier && resolveGlobal(s, held.resolvedSym) >= 0;
}

function compileVariableDeclValue(s: RaiserCompState, node: Node, d: VariableDeclData): void {
	const shape = resolveGlobal(s, node.resolvedSym) < 0 && node.resolvedSym != null && !s.legacyRoots.has(node.resolvedSym) && !takesGlobalCell(s, d.initializer) ? packedSlotShapeOf(s.layouts, node.nodeType) : null;
	if (shape != null) {
		const value = d.initializer != null ? compilePackedExpr(s, d.initializer, node.nodeType!) : allocPackedValue(s, s.layouts, node.nodeType!);
		declareLocal(s, declaredSymbol(node, d.declName), value.base, false, shape);
		if (d.initializer != null) notePackedMove(s, node.nodeType!, d.initializer);
		return;
	}

	const placeholderNull = d.initializer != null && d.initializer.kind == NodeKind.NullLiteral && isScalarClass(regClassOf(s, node.nodeType));
	if (d.initializer != null && !placeholderNull) {
		const declared = skipModifier(node.nodeType);
		if (d.initializer.kind == NodeKind.Identifier && (declared == null || !isPlainFunctionPointer(declared))) {
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
		const reg = compileExpr(s, d.initializer);
		const global = resolveGlobal(s, node.resolvedSym);
		if (global >= 0) {
			emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, reg, global, 0));
			return;
		}
		const declaredClass = node.nodeType == null ? classOfReg(s, reg) : regClassOf(s, node.nodeType);
		let local = reg;
		if (regIsFixedLocal(s, reg) || classOfReg(s, reg) != declaredClass) {
			local = allocReg(s, declaredClass);
			emitInst(s, raiserABC(RaiserOpcode.Move, local, reg, 0));
		}
		declareLocal(s, declaredSymbol(node, d.declName), local, isStr);
		if (isMoveTempFromPlace(node, d.initializer)) {
			s.moveTempAt = codeLen(s);
			s.moveTempReg = local;
			s.moveTempSource = d.initializer;
		}
	} else {
		const global = resolveGlobal(s, node.resolvedSym);
		if (global >= 0 && zeroIsNil(node.nodeType)) return;
		const reg = emitZeroValue(s, node.nodeType);
		if (global >= 0) {
			emitInst(s, raiserABC(RaiserOpcode.StoreGlobal, reg, global, 0));
			return;
		}
		const declaredClass = regClassOf(s, node.nodeType);
		if (classOfReg(s, reg) != declaredClass) {
			const slot = allocReg(s, declaredClass);
			emitInst(s, raiserABC(RaiserOpcode.Move, slot, reg, 0));
			declareLocal(s, declaredSymbol(node, d.declName), slot);
			return;
		}
		declareLocal(s, declaredSymbol(node, d.declName), reg);
	}
}

function isMoveTempFromPlace(node: Node, initializer: Node): boolean {
	const sym = node.resolvedSym;
	if (sym == null || !hasFlag(sym, SymbolFlag.SinkTemp)) return false;
	const k = initializer.kind;
	return k == NodeKind.MemberExpr || k == NodeKind.ArrayAccess || k == NodeKind.HiddenDeref;
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
	const outerLocals = loadConstGlobalsBeforeLoop(s, [d.doCondition, d.doBody]);
	const outerReads = loadInvariantReadsBeforeLoop(s, [d.doCondition, d.doBody]);
	compileDoWhileLoop(s, d);
	s.locals.items.shrink(outerLocals);
	s.loopReadNodes.shrink(outerReads);
	s.loopReadRegs.shrink(outerReads);
}

function compileDoWhileLoop(s: RaiserCompState, d: DoWhileStmtData): void {
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
	const outerLocals = loadConstGlobalsBeforeLoop(s, [d.whileCondition, d.whileBody]);
	const outerReads = loadInvariantReadsBeforeLoop(s, [d.whileCondition, d.whileBody]);
	compileWhileLoop(s, d);
	s.locals.items.shrink(outerLocals);
	s.loopReadNodes.shrink(outerReads);
	s.loopReadRegs.shrink(outerReads);
}

function loadConstGlobalsBeforeLoop(s: RaiserCompState, parts: (Node | null)[]): int32 {
	const outerLocals = s.locals.items.length;
	const declared = new HashSet<Symbol>();
	const read: Symbol[] = [];
	for (const part of parts) collectConstGlobalReads(s, part, declared, read);
	for (const sym of read) {
		if (declared.has(sym) || resolveLocal(s, sym) >= 0) continue;
		const reg = allocFor(s, sym.symbolType);
		emitInst(s, raiserABC(RaiserOpcode.LoadGlobal, reg, resolveGlobal(s, sym), 0));
		declareLocal(s, sym, reg);
	}
	return outerLocals;
}

function loadInvariantReadsBeforeLoop(s: RaiserCompState, parts: (Node | null)[]): int32 {
	const outerReads = s.loopReadNodes.length;
	const written = new HashSet<Symbol>();
	const reads: Node[] = [];
	for (const part of parts) collectLoopReads(part, written, reads);
	for (const call of reads) {
		const d = call.data as CallExprData;
		if (!invariantOperand(s, (d.callee.data as MemberExprData).object, written) || !invariantOperand(s, d.arguments[0], written)) continue;
		const reg = compileExpr(s, call);
		s.loopReadNodes.push(call);
		s.loopReadRegs.push(reg);
	}
	return outerReads;
}

function collectLoopReads(node: Node | null, written: HashSet<Symbol>, reads: Node[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr || node.kind == NodeKind.ClassDecl) return;
	const target = writtenTarget(node);
	if (target != null && target.kind == NodeKind.Identifier && target.resolvedSym != null) written.add(target.resolvedSym!);
	if (node.kind == NodeKind.CallExpr && isStrIndexReadCall(node)) reads.push(node);
	forEachChild(node, (child: Node): void => { collectLoopReads(child, written, reads); });
}

function writtenTarget(node: Node): Node | null {
	if (node.kind == NodeKind.BinaryExpr && isAssignOp((node.data as BinaryExprData).operator)) return (node.data as BinaryExprData).left;
	if (node.kind == NodeKind.UpdateExpr) return (node.data as UpdateExprData).updateArg;
	if (node.kind == NodeKind.HiddenAddr) return (node.data as HiddenDerefData).expr;
	if (node.kind == NodeKind.OutExpr) return (node.data as OutExprData).outArg;
	return null;
}

function invariantOperand(s: RaiserCompState, node: Node, written: HashSet<Symbol>): boolean {
	if (node.kind == NodeKind.NumberLiteral) return true;
	if (node.kind != NodeKind.Identifier || node.resolvedSym == null || written.has(node.resolvedSym!)) return false;
	return resolveLocal(s, node.resolvedSym) >= 0;
}

function collectConstGlobalReads(s: RaiserCompState, node: Node | null, declared: HashSet<Symbol>, read: Symbol[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr || node.kind == NodeKind.ClassDecl) return;
	const sym = node.resolvedSym;
	if (node.kind == NodeKind.VariableDecl && sym != null) declared.add(sym);
	if (node.kind == NodeKind.Identifier && isConstGlobal(s, sym) && !read.includes(sym!)) read.push(sym!);
	forEachChild(node, (child: Node): void => { collectConstGlobalReads(s, child, declared, read); });
}

function isConstGlobal(s: RaiserCompState, sym: Symbol | null): boolean {
	if (sym == null || sym.symbolKind != SymbolKind.Variable || !hasFlag(sym, SymbolFlag.Global)) return false;
	if (hasFlag(sym, SymbolFlag.Mutable) || hasFlag(sym, SymbolFlag.StaticLocal) || hasFlag(sym, SymbolFlag.Static)) return false;
	if (sym.symbolType == null || sym.symbolType.kind == TypeKind.Var) return false;
	return resolveGlobal(s, sym) >= 0;
}

function compileWhileLoop(s: RaiserCompState, d: WhileStmtData): void {
	const loopStart = codeLen(s);
	pushLoop(s, loopStart, d.whileLabel);

	const exitJumps = condJumps(s, d.whileCondition, false);
	const bodyStart = codeLen(s);

	compileStmt(s, d.whileBody);

	const continued = currentLoop(s).continuePatches.items.length > 0;
	patchLoopContinues(s);

	// Step and test in one instruction, repeat the test at the bottom, or jump back to loop start
	if (!continued && fuseCountedStep(s, loopStart, exitJumps, bodyStart)) {
	} else if (isRepeatableTest(d.whileCondition)) {
		patchJumpsTo(s, condJumps(s, d.whileCondition, true), bodyStart);
	} else {
		const backOffset = loopStart - codeLen(s) - 1;
		emitInst(s, raiserAx(RaiserOpcode.Jump, backOffset));
	}

	// Patch exit + break jumps
	patchJumpsTo(s, exitJumps, codeLen(s));
	patchLoopBreaks(s);
}

// A condition built only from reads and operators can be compiled a second time, at the bottom of
// the loop, where it branches back to the body: the loop then runs one branch per iteration, where
// the test at the top costs a branch and a jump. Anything that registers code or a constant per
// compile (a call, a function, an object) is left to the jump.
function isRepeatableTest(node: Node): boolean {
	return match (node.kind) {
		NodeKind.Identifier | NodeKind.NumberLiteral | NodeKind.BooleanLiteral => true,
		NodeKind.MemberExpr => isRepeatableTest((node.data as MemberExprData).object),
		NodeKind.ArrayAccess => isRepeatableTest((node.data as ArrayAccessData).array) && isRepeatableTest((node.data as ArrayAccessData).index),
		NodeKind.HiddenStdConv => isRepeatableTest((node.data as HiddenStdConvData).convExpr),
		NodeKind.HiddenDeref => isRepeatableTest((node.data as HiddenDerefData).expr),
		NodeKind.UnaryExpr => {
			const u = node.data as UnaryExprData;
			return (u.unaryOp == "!" || u.unaryOp == "-") && isRepeatableTest(u.operand);
		},
		NodeKind.BinaryExpr => {
			const b = node.data as BinaryExprData;
			return !isAssignOp(b.operator) && b.operator != "instanceof" && isRepeatableTest(b.left) && isRepeatableTest(b.right);
		},
		_ => false,
	};
}

function markWhileCounterStep(s: RaiserCompState, decl: Node, loop: Node): void {
	const sym = decl.resolvedSym;
	if (sym == null || (decl.data as VariableDeclData).declKind != DeclKind.Let || resolveGlobal(s, sym) >= 0) return;
	const w = loop.data as WhileStmtData;
	if (w.whileBody.kind != NodeKind.BlockStmt) return;
	const body = (w.whileBody.data as BlockStmtData).statements;
	if (body.length == 0 || body[body.length - 1].kind != NodeKind.ExprStmt) return;
	markBoundedCounterStep(sym, w.whileCondition, body.slice(0, body.length - 1), (body[body.length - 1].data as ExprStmtData).expr);
}

// A loop whose condition is one `i >= bound` exit branch, after at most a constant load of the bound, and
// whose body ends in `i += 1` that every path of the body reaches, turns that step into one ForLtI64: it steps
// i, counts the iteration and branches back to the body while i < bound, reading the bound register as the
// condition would.
function fuseCountedStep(s: RaiserCompState, loopStart: int32, exitJumps: int32[], bodyStart: int32): boolean {
	const stepPc = codeLen(s) - 1;
	if (exitJumps.length != 1 || exitJumps[0] != bodyStart - 1 || stepPc < bodyStart) return false;
	const test = s.code[bodyStart - 1];
	const step = s.code[stepPc];
	if (test.op != RaiserOpcode.BrGeI64 && test.op != RaiserOpcode.BrGeI64Imm) return false;
	if (step.op != RaiserOpcode.AddI64Imm || step.a != test.a || step.b != test.a || immValue(step.c) != 1) return false;
	const prefix = bodyStart - 1 - loopStart;
	if (prefix > 1) return false;
	const load = s.code[loopStart];
	if (prefix == 1) {
		if (test.op != RaiserOpcode.BrGeI64 || load.a != test.b || regIsFixedLocal(s, test.b as int32)) return false;
		if (load.op != RaiserOpcode.LoadInt && load.op != RaiserOpcode.LoadConst) return false;
	}
	for (let pc = bodyStart; pc < stepPc; pc += 1) {
		const inst = s.code[pc];
		if (landsPast(inst, pc, stepPc + 1) || inst.op == RaiserOpcode.Try || inst.op == RaiserOpcode.Catch || inst.op == RaiserOpcode.Finally || inst.op == RaiserOpcode.FinallyEnd) return false;
		if (prefix == 1 && namesRegister(inst, load.a)) return false;
	}
	const op = test.op == RaiserOpcode.BrGeI64 ? RaiserOpcode.ForLtI64 : RaiserOpcode.ForLtI64Imm;
	s.code[stepPc] = raiserABC(op, test.a, test.b, branchField(bodyStart - stepPc - 1));
	return true;
}

export function threadConstantTests(s: RaiserCompState): void {
	const code = s.code;
	for (const inst of code) {
		if (inst.op == RaiserOpcode.Try || inst.op == RaiserOpcode.Catch || inst.op == RaiserOpcode.Finally || inst.op == RaiserOpcode.FinallyEnd) return;
	}
	const landed: boolean[] = code.map((): boolean => false);
	for (let pc = 0; pc < code.length; pc += 1) {
		const to = jumpDestination(code[pc], pc);
		if (to >= 0 && to < code.length) landed[to] = true;
		if (to < 0 && landsPast(code[pc], pc as int32, (pc + 2) as int32) && pc + 1 + code[pc].c < code.length) landed[pc + 1 + code[pc].c] = true;
	}
	for (let pc = 0; pc < code.length; pc += 1) {
		const test = jumpDestination(code[pc], pc);
		if (test <= pc || test + 1 >= code.length) continue;
		const dest = constantTestDestination(s, test, pc, landed);
		if (dest > pc) patchJumpTo(s, pc as int32, dest as int32);
	}
}

function jumpDestination(inst: RaiserInstruction, pc: number): number {
	if (inst.op == RaiserOpcode.Jump) return pc + 1 + getSignedAx(inst);
	if (isBranchI64(inst.op)) return pc + 1 + (branchOffset(inst.c) as number);
	return -1;
}

function constantTestDestination(s: RaiserCompState, test: number, from: number, landed: boolean[]): number {
	const code = s.code;
	const t = code[test];
	const isTruthy = t.op == RaiserOpcode.BTruthy && t.c == 1 && code[test + 1].op == RaiserOpcode.Jump;
	const isImmBranch = t.op == RaiserOpcode.BrEqI64Imm || t.op == RaiserOpcode.BrNeI64Imm;
	if (!isTruthy && !isImmBranch) return -1;
	const at = constantLoadBefore(s, t.a, from, landed);
	if (at < 0) return -1;
	const load = code[at];
	let value: int64 = 0;
	if (load.op == RaiserOpcode.LoadInt) value = immValue(load.b);
	else {
		const k = s.constants[getBx(load)];
		if (k.kind != RaiserValueKind.Bool && k.kind != RaiserValueKind.Int) return -1;
		value = k.intVal as int64;
	}
	if (isTruthy) return value != 0 ? test + 2 : jumpDestination(code[test + 1], test + 1);
	const taken = (value == immValue(t.b)) == (t.op == RaiserOpcode.BrEqI64Imm);
	return taken ? jumpDestination(t, test) : test + 1;
}

function constantLoadBefore(s: RaiserCompState, reg: number, from: number, landed: boolean[]): number {
	const code = s.code;
	for (let q = from - 1; q >= 0; q -= 1) {
		if (landed[q + 1]) return -1;
		const inst = code[q];
		if (inst.a == reg && (inst.op == RaiserOpcode.LoadInt || inst.op == RaiserOpcode.LoadConst)) return q;
		if (namesRegister(inst, reg) || inst.op == RaiserOpcode.Jump || inst.op == RaiserOpcode.Ret || inst.op == RaiserOpcode.RetN || inst.op == RaiserOpcode.Throw) return -1;
	}
	return -1;
}

function namesRegister(inst: RaiserInstruction, reg: number): boolean {
	const fields = [inst.a, inst.b, inst.c];
	for (let slot = 0; slot < 3; slot += 1) {
		const role = opRole(inst.op, slot as int32);
		if (role == RaiserRole.None) continue;
		if (fields[slot] == reg || ((role == RaiserRole.IntPair || role == RaiserRole.Route) && fields[slot] + 1 == reg)) return true;
	}
	return opHasSite(inst.op) && reg > inst.a && reg <= inst.a + siteArgCount(inst);
}

// --- For Statement ---
// for (init; cond; update) body → init; while (cond) { body; update; }

function compileForStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as ForStmtData;

	// Compile init
	if (d.forInit != null) {
		compileStmt(s, d.forInit);
	}

	const outerLocals = loadConstGlobalsBeforeLoop(s, [d.forCondition, d.forBody, d.forUpdate]);
	const outerReads = loadInvariantReadsBeforeLoop(s, [d.forCondition, d.forBody, d.forUpdate]);
	compileForLoop(s, d);
	s.locals.items.shrink(outerLocals);
	s.loopReadNodes.shrink(outerReads);
	s.loopReadRegs.shrink(outerReads);
}

function compileForLoop(s: RaiserCompState, d: ForStmtData): void {
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
	const idxReg = allocWord(s);
	emitLoadConst(s, idxReg, raiserInt(0));

	// Length register (recomputed each iteration)
	const lenReg = allocWord(s);

	// Element register — declared as a local for the binding name
	const bindingSym = declaredSymbol(node, d.forOfBinding);
	const elemReg = allocFor(s, bindingSym.symbolType);
	declareLocal(s, bindingSym, elemReg);

	const loopStart = codeLen(s);
	pushLoop(s, loopStart, d.forOfLabel);

	const headReg = readsLocation ? compileExpr(s, d.forOfIterable) : arrReg;
	// Condition: if idx < len, skip past the exit jump (continue loop)
	emitInst(s, raiserABC(lenOp, lenReg, headReg, 0));
	emitInst(s, raiserABC(RaiserOpcode.BltI64, idxReg, lenReg, 1));
	const exitJump = emitJumpPlaceholder(s);

	if (isString) {
		const callReg = allocBlock(s, [classOfReg(s, elemReg), RaiserRegClass.Ref, RaiserRegClass.Word]);
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
	const nowReg = allocWord(s);
	const messageReg = allocRef(s);
	emitInst(s, raiserABC(lenOp, nowReg, tailReg, 0));
	emitInst(s, raiserABC(RaiserOpcode.BeqI64, nowReg, lenReg, 2));
	emitLoadConst(s, messageReg, raiserConstString(`the length of the ${isString ? "string" : "array"} changed while iterating over it`));
	emitInst(s, raiserABC(RaiserOpcode.Throw, messageReg, 0, 0));

	// Increment index: __i++
	const oneReg = allocWord(s);
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
//                         (c=FINALLY_LEAVE: a jump out of the finally body drops it)
//
// The Finally marker is emitted even when the source has no finally clause,
// so the normal path always has exactly one place that pops the safepoint;
// without a finally clause the catch body has no safepoint and jumps past
// FinallyEnd.
function compileTryCatchStmt(s: RaiserCompState, node: Node): void {
	const d = node.data as TryCatchStmtData;
	const routeReg = allocBlock(s, [RaiserRegClass.Word, RaiserRegClass.Dyn]);
	const tryIdx = emitAbxPlaceholder(s, RaiserOpcode.Try);
	const guardedTry: RaiserTryInfo = { finallyBody: d.finallyBody, routeReg, inFinallyBody: false, returnTop: -1 };
	s.tries.push(guardedTry);
	compileStmt(s, d.tryBody);
	s.tries.pop();
	let returnTop = guardedTry.returnTop;
	const toFinally = emitJumpPlaceholder(s);

	let catchIdx = -1;
	let catchEnd = -1;
	let catchGuard = -1;
	let catchReg = 0;
	if (d.hasCatchClause) {
		catchIdx = emitAbxPlaceholder(s, RaiserOpcode.Catch);
		catchReg = allocDyn(s);
		if (d.catchName == "") emitInst(s, raiserABC(RaiserOpcode.RcDec, catchReg, 1, 0));
		if (d.finallyBody != null) {
			catchGuard = emitAbxPlaceholder(s, RaiserOpcode.Try);
			s.tries.push({ finallyBody: d.finallyBody, routeReg, inFinallyBody: false, returnTop: -1 });
		}
		const savedLocals = s.locals.items.length;
		if (d.catchName != "") declareLocal(s, declaredSymbol(node, d.catchName), catchReg);
		if (d.catchBody != null) compileStmt(s, d.catchBody);
		s.locals.items.shrink(savedLocals);
		if (catchGuard >= 0) returnTop = Math.max(returnTop, s.tries.pop()!.returnTop);
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
	if (d.finallyBody != null) {
		if (s.nextReg <= returnTop) s.nextReg = returnTop + 1;
		s.tries.push({ finallyBody: null, routeReg, inFinallyBody: true, returnTop: -1 });
		compileStmt(s, d.finallyBody);
		s.tries.pop();
	}
	emitInst(s, raiserABC(RaiserOpcode.FinallyEnd, routeReg, 0, 0));
	if (d.hasCatchClause && catchGuard < 0) patchJumpTo(s, catchEnd, codeLen(s));
}

export function compileBodyReleasingOnRaise(s: RaiserCompState, body: Node, owned: int32): void {
	const routeReg = allocBlock(s, [RaiserRegClass.Word, RaiserRegClass.Dyn]);
	const tryIdx = emitAbxPlaceholder(s, RaiserOpcode.Try);
	s.tries.push({ finallyBody: null, routeReg, inFinallyBody: false, returnTop: -1 });
	compileStmt(s, body);
	s.tries.pop();
	const finIdx = codeLen(s);
	emitInst(s, raiserABC(RaiserOpcode.Finally, routeReg, 0, 0));
	patchAbxTo(s, tryIdx, RaiserOpcode.Try, 0, finIdx);
	emitInst(s, raiserABC(RaiserOpcode.BeqI64Imm, routeReg, immField(1), 1));
	const skip = emitJumpPlaceholder(s);
	emitInst(s, raiserABC(RaiserOpcode.RcDec, owned, 1, 0));
	patchJumpTo(s, skip, codeLen(s));
	emitInst(s, raiserABC(RaiserOpcode.FinallyEnd, routeReg, 0, 0));
}

function leaveTries(s: RaiserCompState, depth: int32): void {
	const tries = s.tries.slice(0, s.tries.length);
	for (let j = tries.length - 1; j >= depth; j = j - 1) {
		if (tries[j].inFinallyBody) {
			emitInst(s, raiserABC(RaiserOpcode.FinallyEnd, tries[j].routeReg, 0, FINALLY_LEAVE));
			continue;
		}
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
			compileStatements(s, cd.caseStmts);
			endPatches.push(emitJumpPlaceholder(s));
			patchJumpTo(s, skipJump, codeLen(s));
		} else {
			// Multiple tests (or-pattern): check each, any match → body
			// Use a matched flag register
			const flagReg = allocWord(s);
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
			const zeroReg = allocWord(s);
			emitLoadConst(s, zeroReg, raiserInt(0));
			emitInst(s, raiserABC(RaiserOpcode.BneI64, flagReg, zeroReg, 1));
			const skipBody = emitJumpPlaceholder(s);
			compileStatements(s, cd.caseStmts);
			endPatches.push(emitJumpPlaceholder(s));
			patchJumpTo(s, skipBody, codeLen(s));
		}
	}

	// Default case
	if (defaultCaseIdx >= 0) {
		const dd = d.switchCases[defaultCaseIdx].data as SwitchCaseData;
		compileStatements(s, dd.caseStmts);
	}

	// Patch all end jumps to here
	for (const patch of endPatches) {
		patchJumpTo(s, patch, codeLen(s));
	}
}
