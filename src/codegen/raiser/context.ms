// Raiser codegen — Compiler state + emit helpers
// Register allocator, constant pool builder, instruction emitter.

import {
	RaiserOpcode, RaiserInstruction, RaiserRegClass,
	raiserABC, raiserABx, raiserAx, getSignedAx, fitsImm, immField, isBranchI64, branchField, branchOffset
} from "../../raiser/bytecode";
import { RaiserValue, RaiserValueKind, RaiserClassType, raiserInt, raiserConstString, raiserNil } from "../../raiser/value";
import { Node, Symbol, SymbolKind, SymbolFlag, Type, TypeKind } from "../../ast/node";
import { RaiserCopyPlan } from "../../raiser/valueCopy";
import { CheckerError, Severity } from "../../checker/context";
import { placedInstanceOf } from "../../checker/instantiate";

// --- Bytecode-compiler error queue ---
// The expression/statement compilers used to silently emit LoadConst nil
// for constructs they could not compile, hiding comptime failures until
// they misbehaved at macro-expansion time. The queue collects those; the
// macro engine drains it into EngineMacroResult.errors after each compile
// (eval.ms), where expand.ms renders them with span.

let _raiserCompileErrors: CheckerError[] = [];

let _raiserModulePath: string = "";

export function setRaiserModulePath(path: string): void {
	_raiserModulePath = path;
}

export function getRaiserModulePath(): string {
	return _raiserModulePath;
}

export function queueRaiserCompileError(message: string, line: int32, column: int32): void {
	const tagged = _raiserModulePath == "" ? message : `[${_raiserModulePath}] ${message}`;
	_raiserCompileErrors.push({
		message: tagged,
		line: line,
		column: column,
		endLine: 0,
		endColumn: 0,
		fatal: false,
		severity: Severity.Error,
		tags: 0,
	});
}

export function takeRaiserCompileErrors(): CheckerError[] {
	const out = _raiserCompileErrors;
	_raiserCompileErrors = [];
	return out;
}

export function restoreRaiserCompileErrors(errors: CheckerError[]): void {
	_raiserCompileErrors = errors;
}

// --- Locals ---

export interface RaiserLocal {
	sym: Symbol;
	reg: int32;
	isString: boolean;
}

export interface RaiserLocals {
	items: RaiserLocal[];
}

// --- Loop tracking ---

export interface RaiserBreakPatches {
	items: int32[];
}

export interface RaiserLoopInfo {
	startIp: int32;
	label: string;
	breakPatches: RaiserBreakPatches;
	// Each loop kind patches these to its own "re-enter" point: for-of/for-stmt
	// to the update step (NOT loop start — else continue skips the update and
	// the loop counter never advances), while to before the backjump, do-while
	// to before the bottom condition.
	continuePatches: RaiserBreakPatches;
	tryDepth: int32;
}

export interface RaiserLoopStack {
	items: RaiserLoopInfo[];
}

// --- Function map ---

export interface RaiserFuncMap {
	symbolIndices: HashMap<Symbol, int32>;
	ctorIndices: HashMap<Symbol, int32>;
	initIndices: HashMap<Symbol, int32>;
}

export function createFuncMap(): RaiserFuncMap {
	return { symbolIndices: new HashMap<Symbol, int32>(), ctorIndices: new HashMap<Symbol, int32>(), initIndices: new HashMap<Symbol, int32>() };
}

export interface RaiserGlobalEntry {
	symbol: Symbol;
	index: int32;
	initGuard: int32;
}

export interface RaiserGlobalMap {
	items: RaiserGlobalEntry[];
}

// --- Compiler state ---

export interface RaiserCompState {
	code: RaiserInstruction[];
	constants: RaiserValue[];
	nextReg: int32;
	regClasses: RaiserRegClass[];
	locals: RaiserLocals;
	loopStack: RaiserLoopStack;
	funcMap: RaiserFuncMap;
	copyTypes: Type[];
	copyPlans: RaiserCopyPlan[];
	classTypes: RaiserClassType[];
	globals: RaiserGlobalMap;
	receiverReg: int32;
	tries: RaiserTryInfo[];
}

export interface RaiserTryInfo {
	finallyBody: Node | null;
	routeReg: int32;
}

export function createCompState(): RaiserCompState {
	const code: RaiserInstruction[] = [];
	const constants: RaiserValue[] = [];
	const localItems: RaiserLocal[] = [];
	const locals: RaiserLocals = { items: localItems };
	const loopItems: RaiserLoopInfo[] = [];
	const loopStack: RaiserLoopStack = { items: loopItems };
	return { code, constants, nextReg: 0, regClasses: [], locals, loopStack,
		funcMap: createFuncMap(), copyTypes: [], copyPlans: [], classTypes: [], globals: { items: [] }, receiverReg: -1, tries: [] };
}

export function classSymOfType(t: Type | null): Symbol | null {
	let cur = t;
	if (cur != null && cur.kind == TypeKind.Ref && cur.typeReturn != null) cur = cur.typeReturn;
	if (cur == null || cur.sym == null) return null;
	return cur.sym;
}

export function raiserClassKey(classSym: Symbol): string {
	const own = classSymOfType(classSym.symbolType);
	const sym = own != null ? own : classSym;
	if (sym.instantiatedFrom != null) return sym.name;
	return sym.modulePath + ":" + sym.name + "#" + sym.disamb;
}

export function resolveGlobal(s: RaiserCompState, sym: Symbol | null): int32 {
	if (sym == null || !sym.symFlags.has(SymbolFlag.Global)) return -1;
	for (const entry of s.globals.items) {
		if (entry.symbol == sym) return entry.index;
	}
	return -1;
}

export function resolveStaticInitGuard(s: RaiserCompState, sym: Symbol | null): int32 {
	if (sym == null || !sym.symFlags.has(SymbolFlag.StaticLocal)) return -1;
	for (const entry of s.globals.items) {
		if (entry.symbol == sym) return entry.initGuard;
	}
	return -1;
}

export function emitInst(s: RaiserCompState, inst: RaiserInstruction): void {
	s.code.push(inst);
}

export function addConst(s: RaiserCompState, val: RaiserValue): int32 {
	const idx = s.constants.length;
	s.constants.push(val);
	return idx;
}

export function allocReg(s: RaiserCompState, cls: RaiserRegClass): int32 {
	let r = s.nextReg;
	while (r < s.regClasses.length && s.regClasses[r] != cls) r = r + 1;
	if (r == s.regClasses.length) s.regClasses.push(cls);
	s.nextReg = r + 1;
	return r;
}

export function allocBlock(s: RaiserCompState, classes: RaiserRegClass[]): int32 {
	let start = s.nextReg;
	while (!blockFits(s, start, classes)) start = start + 1;
	for (let i = 0; i < classes.length; i = i + 1) {
		if (start + i == s.regClasses.length) s.regClasses.push(classes[i]);
	}
	s.nextReg = start + classes.length;
	return start;
}

function blockFits(s: RaiserCompState, start: int32, classes: RaiserRegClass[]): boolean {
	for (let i = 0; i < classes.length; i = i + 1) {
		if (start + i < s.regClasses.length && s.regClasses[start + i] != classes[i]) return false;
	}
	return true;
}

export function allocWord(s: RaiserCompState): int32 {
	return allocReg(s, RaiserRegClass.Word);
}

export function allocRef(s: RaiserCompState): int32 {
	return allocReg(s, RaiserRegClass.Ref);
}

export function allocDyn(s: RaiserCompState): int32 {
	return allocReg(s, RaiserRegClass.Dyn);
}

export function classOfReg(s: RaiserCompState, reg: int32): RaiserRegClass {
	if (reg < 0 || reg >= s.regClasses.length) throw new Error(`internal: register R${reg} was never allocated`);
	return s.regClasses[reg];
}

// Reset temporary registers after each statement.
// Locals are preserved (their registers remain bound); temps above the
// highest live local register are reclaimed for reuse on the next statement.
//
// IMPORTANT: locals are NOT guaranteed to occupy contiguous registers
// R[0..localsCount-1]. A `const k = t.nodeType.kind;` chained MemberExpr
// allocates an intermediate temp at R1 (for the inner LoadField result)
// before declaring `k` at R2 — leaving R1 as a live-but-anonymous slot.
// Using `locals.items.length` would set nextReg=2 and clobber R2 (`k`)
// on the next statement. Compute max(local.reg)+1 instead.
export function resetTemps(s: RaiserCompState): void {
	let maxReg = -1;
	for (const local of s.locals.items) {
		if (local.reg > maxReg) maxReg = local.reg;
	}
	s.nextReg = maxReg + 1;
}

// --- Typed emit helpers ---

export function emitLoadConst(s: RaiserCompState, reg: int32, val: RaiserValue): void {
	if (val.kind == RaiserValueKind.Int && fitsImm(val.intVal)) {
		emitInst(s, raiserABC(RaiserOpcode.LoadInt, reg, immField(val.intVal), 0));
		return;
	}
	const ci = addConst(s, val);
	const inst = raiserABx(RaiserOpcode.LoadConst, reg, ci);
	emitInst(s, inst);
}

export function emitRet(s: RaiserCompState, reg: int32): void {
	emitInst(s, raiserABC(RaiserOpcode.Ret, reg, 0, 0));
}

export function emitHalt(s: RaiserCompState): void {
	emitInst(s, raiserABC(RaiserOpcode.Halt, 0, 0, 0));
}

// --- Locals helpers ---

export function declareLocal(s: RaiserCompState, sym: Symbol, reg: int32, isString: boolean = false): void {
	const local: RaiserLocal = { sym, reg, isString };
	s.locals.items.push(local);
}

export function declaredSymbol(node: Node, name: string): Symbol {
	if (node.resolvedSym == null) throw new Error(`internal: '${name}' reached Raiser codegen without a symbol`);
	return node.resolvedSym!;
}

export function isLocalString(s: RaiserCompState, sym: Symbol | null): boolean {
	for (let i = s.locals.items.length - 1; i >= 0; i = i - 1) {
		if (s.locals.items[i].sym == sym) {
			return s.locals.items[i].isString;
		}
	}
	return false;
}

export function resolveLocal(s: RaiserCompState, sym: Symbol | null): int32 {
	for (let i = s.locals.items.length - 1; i >= 0; i = i - 1) {
		if (s.locals.items[i].sym == sym) {
			return s.locals.items[i].reg;
		}
	}
	return -1;
}

export function regIsFixedLocal(s: RaiserCompState, reg: int32): boolean {
	for (const local of s.locals.items) {
		if (local.reg == reg) return true;
	}
	return false;
}

// --- Condition helpers ---

export function emitBranchIfFalsy(s: RaiserCompState, condReg: int32): int32 {
	emitInst(s, raiserABC(RaiserOpcode.BTruthy, condReg, 0, 1));
	return emitJumpPlaceholder(s);
}

// --- Jump patching ---

export function emitJumpPlaceholder(s: RaiserCompState): int32 {
	const idx = s.code.length;
	emitInst(s, raiserAx(RaiserOpcode.Jump, 0));
	return idx;
}

export function patchJumpTo(s: RaiserCompState, idx: int32, target: int32): void {
	const offset = target - idx - 1;
	const placed = s.code[idx];
	if (isBranchI64(placed.op)) {
		placed.c = branchField(offset);
		return;
	}
	s.code[idx] = raiserAx(RaiserOpcode.Jump, offset);
}

export function patchJumpsTo(s: RaiserCompState, jumps: int32[], target: int32): void {
	for (const j of jumps) patchJumpTo(s, j, target);
}

export function codeLen(s: RaiserCompState): int32 {
	return s.code.length;
}

// Try/Catch carry their target as a FORWARD offset from their own slot, so
// both are emitted blank and patched once the handler layout is known.
export function emitAbxPlaceholder(s: RaiserCompState, op: RaiserOpcode): int32 {
	const idx = s.code.length;
	emitInst(s, raiserABx(op, 0, 0));
	return idx;
}

export function patchAbxTo(s: RaiserCompState, idx: int32, op: RaiserOpcode, a: int32, target: int32): void {
	s.code[idx] = raiserABx(op, a, target - idx);
}

// --- Loop helpers ---

export function pushLoop(s: RaiserCompState, startIp: int32, label: string): void {
	const info: RaiserLoopInfo = {
		startIp,
		label,
		breakPatches: { items: [] },
		continuePatches: { items: [] },
		tryDepth: s.tries.length,
	};
	s.loopStack.items.push(info);
}

export function popLoop(s: RaiserCompState): RaiserLoopInfo {
	const len = s.loopStack.items.length;
	const info = s.loopStack.items[len - 1];
	s.loopStack.items.shrink(len - 1);
	return info;
}

export function currentLoop(s: RaiserCompState): RaiserLoopInfo {
	const len = s.loopStack.items.length;
	return s.loopStack.items[len - 1];
}

export function jumpTarget(s: RaiserCompState, label: string): RaiserLoopInfo | null {
	for (let i = s.loopStack.items.length - 1; i >= 0; i = i - 1) {
		const loop = s.loopStack.items[i];
		if (label == "" || loop.label == label) return loop;
	}
	return null;
}

// --- Function map helpers ---

type RaiserFuncDemandFn = (idx: int32) => void;

let _raiserFuncDemandFn: RaiserFuncDemandFn = (_idx: int32): void => {};

export function registerRaiserFuncDemand(fn: RaiserFuncDemandFn): void {
	_raiserFuncDemandFn = fn;
}

export function clearRaiserFuncDemand(): void {
	_raiserFuncDemandFn = (_idx: int32): void => {};
}

function demandIndex(index: int32 | null): int32 {
	if (index == null) return -1;
	_raiserFuncDemandFn(index);
	return index;
}

export function resolveRoutine(s: RaiserCompState, sym: Symbol | null): int32 {
	return sym != null && isRoutineSym(sym) ? demandIndex(s.funcMap.symbolIndices.get(placedInstanceOf(sym))) : -1;
}

export function resolveConstructor(s: RaiserCompState, classSym: Symbol): int32 {
	return demandIndex(s.funcMap.ctorIndices.get(placedInstanceOf(classSym)));
}

export function resolveClassInit(s: RaiserCompState, classSym: Symbol): int32 {
	return demandIndex(s.funcMap.initIndices.get(placedInstanceOf(classSym)));
}

// --- Builtin helpers ---

// --- Closure pair helpers ---
// Emit a closure pair object { fn: funcIdx, env: envReg | -1 } into destReg.
// envVal = -1 sentinel means non-capturing (no env), otherwise envVal is a register holding the env.

export function emitClosurePair(s: RaiserCompState, funcIdx: int32, envReg: int32): int32 {
	const pairReg = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.NewObject, pairReg, 0, 0));
	const fnReg = allocWord(s);
	emitLoadConst(s, fnReg, raiserInt(funcIdx));
	const fnConst = addConst(s, raiserConstString("fn"));
	emitInst(s, raiserABC(RaiserOpcode.StoreField, pairReg, fnConst, fnReg));
	const envConst = addConst(s, raiserConstString("env"));
	if (envReg < 0) {
		// Non-capturing: store -1 sentinel
		const sentinelReg = allocWord(s);
		emitLoadConst(s, sentinelReg, raiserInt(-1));
		emitInst(s, raiserABC(RaiserOpcode.StoreField, pairReg, envConst, sentinelReg));
	} else {
		// Capturing: store actual env register
		emitInst(s, raiserABC(RaiserOpcode.StoreField, pairReg, envConst, envReg));
	}
	return pairReg;
}

// --- Loop break-patch helper ---
// Patches all break-jump placeholders to the current code position, then pops the loop.

export function patchLoopBreaks(s: RaiserCompState): void {
	const loop = popLoop(s);
	const target = codeLen(s);
	for (const patchIdx of loop.breakPatches.items) {
		patchJumpTo(s, patchIdx, target);
	}
}

// Patch all `continue` placeholders to land at the current code position.
// Each loop kind calls this at its own re-enter point — see RaiserLoopInfo.
export function patchLoopContinues(s: RaiserCompState): void {
	const loop = currentLoop(s);
	const target = codeLen(s);
	for (const patchIdx of loop.continuePatches.items) {
		patchJumpTo(s, patchIdx, target);
	}
}

type RaiserOnDemandFn = (sym: Symbol) => int32;

let _raiserOnDemandFn: RaiserOnDemandFn = (_sym: Symbol): int32 => {
	return -1;
};

export function registerRaiserOnDemand(fn: RaiserOnDemandFn): RaiserOnDemandFn {
	const previous = _raiserOnDemandFn;
	_raiserOnDemandFn = fn;
	return previous;
}

export function clearRaiserOnDemand(): void {
	_raiserOnDemandFn = (_sym: Symbol): int32 => {
		return -1;
	};
}

export function isRoutineSym(sym: Symbol): boolean {
	return sym.symbolKind == SymbolKind.Function
		|| sym.symbolKind == SymbolKind.Method
		|| sym.symbolKind == SymbolKind.Macro;
}

export function callRaiserOnDemand(sym: Symbol): int32 {
	if (!isRoutineSym(sym) && sym.symbolKind != SymbolKind.Class) return -1;
	return _raiserOnDemandFn(sym);
}

type RaiserStmtCompilerFn = (s: RaiserCompState, stmt: Node) => void;

let _raiserStmtCompiler: RaiserStmtCompilerFn = (_s: RaiserCompState, stmt: Node): void => {
	queueRaiserCompileError("raiser statement compiler not registered",
		stmt.location.line, stmt.location.column);
};

export function registerRaiserStmtCompiler(fn: RaiserStmtCompilerFn): void {
	_raiserStmtCompiler = fn;
}

export function callRaiserStmtCompiler(s: RaiserCompState, stmt: Node): void {
	_raiserStmtCompiler(s, stmt);
}

export function emitTrapNil(s: RaiserCompState, message: string): int32 {
	const cIdx = addConst(s, raiserConstString(message));
	emitInst(s, raiserABx(RaiserOpcode.Trap, 0, cIdx));
	const reg = allocRef(s);
	emitLoadConst(s, reg, raiserNil());
	return reg;
}

// --- Destinations ---

function writesResultAfterReading(op: RaiserOpcode): boolean {
	return match (op) {
		RaiserOpcode.LoadConst | RaiserOpcode.LoadInt | RaiserOpcode.AddI64Imm | RaiserOpcode.SubI64Imm | RaiserOpcode.LoadGlobal | RaiserOpcode.LoadField | RaiserOpcode.LoadIndex
			| RaiserOpcode.AddI64 | RaiserOpcode.SubI64 | RaiserOpcode.MulI64 | RaiserOpcode.DivI64
			| RaiserOpcode.ModI64 | RaiserOpcode.NegI64
			| RaiserOpcode.AddU64 | RaiserOpcode.SubU64 | RaiserOpcode.MulU64 | RaiserOpcode.DivU64 | RaiserOpcode.ModU64
			| RaiserOpcode.AddF64 | RaiserOpcode.SubF64 | RaiserOpcode.MulF64 | RaiserOpcode.DivF64 | RaiserOpcode.NegF64
			| RaiserOpcode.BitAnd | RaiserOpcode.BitOr | RaiserOpcode.BitXor | RaiserOpcode.BitNot
			| RaiserOpcode.ShiftLeft | RaiserOpcode.ShiftRight | RaiserOpcode.ShiftRightU
			| RaiserOpcode.Conv | RaiserOpcode.ArrayLen | RaiserOpcode.StrLen | RaiserOpcode.StrCharAt | RaiserOpcode.ConcatStr
			| RaiserOpcode.IsKind => true,
		_ => false,
	};
}

function skipsInstructions(op: RaiserOpcode): boolean {
	return match (op) {
		RaiserOpcode.BeqI64 | RaiserOpcode.BneI64 | RaiserOpcode.BltI64 | RaiserOpcode.BleI64
			| RaiserOpcode.BgtI64 | RaiserOpcode.BgeI64
			| RaiserOpcode.BeqI64Imm | RaiserOpcode.BneI64Imm | RaiserOpcode.BltI64Imm | RaiserOpcode.BleI64Imm
			| RaiserOpcode.BgtI64Imm | RaiserOpcode.BgeI64Imm
			| RaiserOpcode.BeqF64 | RaiserOpcode.BneF64 | RaiserOpcode.BltF64 | RaiserOpcode.BleF64
			| RaiserOpcode.BgtF64 | RaiserOpcode.BgeF64
			| RaiserOpcode.EqVal | RaiserOpcode.NeVal | RaiserOpcode.EqStr | RaiserOpcode.NeStr | RaiserOpcode.LtStr | RaiserOpcode.LeStr
			| RaiserOpcode.BltU64 | RaiserOpcode.BleU64 | RaiserOpcode.BTruthy => true,
		_ => false,
	};
}

function landsPast(inst: RaiserInstruction, at: int32, limit: int32): boolean {
	if (inst.op == RaiserOpcode.Jump) return at + 1 + getSignedAx(inst) >= limit;
	if (isBranchI64(inst.op)) return at + 1 + (branchOffset(inst.c) as int32) >= limit;
	return skipsInstructions(inst.op) && at + 1 + inst.c >= limit;
}

// A width check that rewrites `reg` where it stands: the range stop of a narrow integer, or the
// float32 rounding of an arithmetic result.
function isInPlaceWidth(inst: RaiserInstruction, reg: int32): boolean {
	if (inst.a != reg) return false;
	return inst.op == RaiserOpcode.NarrowS || inst.op == RaiserOpcode.NarrowU
		|| (inst.op == RaiserOpcode.Conv && inst.b == reg);
}

function writesRegAfterReading(inst: RaiserInstruction, reg: int32): boolean {
	return inst.a == reg && writesResultAfterReading(inst.op);
}

// The code from `startPc` computed `reg` and nothing else is read of it afterwards, so the
// instruction that wrote it can write `target` instead when it is the last one (or the last but the
// width check that follows it), reads its operands before writing, and no jump of the expression lands
// past it (a merge of branches has several writers). Returns how many trailing instructions move, 0 for none.
function lastWriteTail(s: RaiserCompState, startPc: int32, reg: int32): int32 {
	const end = s.code.length;
	if (end <= startPc) return 0;
	let tail: int32 = 1;
	if (end - 1 > startPc && isInPlaceWidth(s.code[end - 1], reg) && writesRegAfterReading(s.code[end - 2], reg)) tail = 2;
	else if (!writesRegAfterReading(s.code[end - 1], reg)) return 0;
	const pastWriter = end - tail + 1;
	for (let i = startPc; i < end - tail; i = i + 1) {
		const inst = s.code[i];
		if (landsPast(inst, i, pastWriter)) return 0;
	}
	return tail;
}

// `reg` is where an expression compiled from `startPc` left its value, `firstTemp` the first register
// that expression could allocate: the value is moved to `target` unless its writer can aim there.
export function landResult(s: RaiserCompState, target: number, startPc: int32, firstTemp: int32, reg: int32): void {
	if (reg == target) return;
	const tail = reg >= firstTemp && classOfReg(s, reg) == classOfReg(s, target as int32) ? lastWriteTail(s, startPc, reg) : 0;
	if (tail > 0) {
		const end = s.code.length;
		s.code[end - tail].a = target;
		if (tail == 2) {
			s.code[end - 1].a = target;
			if (s.code[end - 1].op == RaiserOpcode.Conv) s.code[end - 1].b = target;
		}
		return;
	}
	emitInst(s, raiserABC(RaiserOpcode.Move, target, reg, 0));
}

// A body that cannot fall off its end returns nil only where the code says so: its last instruction
// is a Ret, no jump or skip lands past it, and no handler (whose offsets are not scanned) exists.
function endIsUnreachable(s: RaiserCompState): boolean {
	const end = s.code.length;
	if (end == 0 || s.code[end - 1].op != RaiserOpcode.Ret) return false;
	for (let i = 0; i < end; i = i + 1) {
		const inst = s.code[i];
		if (landsPast(inst, i, end)) return false;
		if (inst.op == RaiserOpcode.Try || inst.op == RaiserOpcode.Catch || inst.op == RaiserOpcode.Finally
			|| inst.op == RaiserOpcode.FinallyEnd) return false;
	}
	return true;
}

export function emitImplicitReturn(s: RaiserCompState): void {
	if (endIsUnreachable(s)) return;
	const nilReg = allocRef(s);
	emitLoadConst(s, nilReg, raiserNil());
	emitRet(s, nilReg);
}
