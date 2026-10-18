// Raiser codegen — Compiler state + emit helpers
// Register allocator, constant pool builder, instruction emitter.

import {
	RaiserOpcode, RaiserInstruction,
	raiserABC, raiserABx, raiserAx, getSignedAx
} from "../../raiser/bytecode";
import { RaiserValue, RaiserClassType, raiserInt, raiserString, raiserNil } from "../../raiser/value";
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
}

export interface RaiserLoopStack {
	items: RaiserLoopInfo[];
}

// --- Function map ---

export interface RaiserFuncEntry {
	name: string;
	index: int32;
}

export interface RaiserFuncMap {
	symbolIndices: HashMap<Symbol, int32>;
	ctorIndices: HashMap<Symbol, int32>;
	initIndices: HashMap<Symbol, int32>;
}

export interface RaiserEnumMap {
	items: RaiserFuncEntry[];
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
	// High-water mark of registers ever allocated. resetTemps shrinks
	// nextReg back to (max local reg + 1) between statements, so the
	// final value of nextReg reflects only the live locals, NOT the peak
	// register count needed at runtime. The VM uses this to size each
	// function's call frame — without an accurate peak, it would either
	// over-allocate (waste) or under-allocate (out-of-bounds on temp regs).
	maxRegSeen: int32;
	locals: RaiserLocals;
	loopStack: RaiserLoopStack;
	funcMap: RaiserFuncMap;
	enumMap: RaiserEnumMap;
	copyTypes: Type[];
	copyPlans: RaiserCopyPlan[];
	classTypes: RaiserClassType[];
	globals: RaiserGlobalMap;
	receiverReg: int32;
}

export function createCompState(): RaiserCompState {
	const code: RaiserInstruction[] = [];
	const constants: RaiserValue[] = [];
	const localItems: RaiserLocal[] = [];
	const locals: RaiserLocals = { items: localItems };
	const loopItems: RaiserLoopInfo[] = [];
	const loopStack: RaiserLoopStack = { items: loopItems };
	const enumItems: RaiserFuncEntry[] = [];
	const enumMap: RaiserEnumMap = { items: enumItems };
	return { code, constants, nextReg: 0, maxRegSeen: 0, locals, loopStack,
		funcMap: createFuncMap(), enumMap, copyTypes: [], copyPlans: [], classTypes: [], globals: { items: [] }, receiverReg: -1 };
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

export function allocReg(s: RaiserCompState): int32 {
	const r = s.nextReg;
	s.nextReg = s.nextReg + 1;
	// Track high-water mark — resetTemps() will lower nextReg back, but the
	// VM needs to know the peak we ever reached to size each call frame.
	if (s.nextReg > s.maxRegSeen) s.maxRegSeen = s.nextReg;
	return r;
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

// --- Enum helpers ---
// Encodes enum entries as "EnumName.MemberName" → index, reusing RaiserFuncEntry.

export function declareEnum(s: RaiserCompState, enumName: string, members: string[]): void {
	for (let i = 0; i < members.length; i = i + 1) {
		const key = `${enumName}.${members[i]}`;
		const entry: RaiserFuncEntry = { name: key, index: i };
		s.enumMap.items.push(entry);
	}
}

// Returns the enumMap entry index for an "EnumName.Member" key (caller reads
// .index for the value, which may be negative), or -1 if not an enum constant.
export function findEnumConstant(s: RaiserCompState, key: string): int32 {
	for (let i = 0; i < s.enumMap.items.length; i = i + 1) {
		if (s.enumMap.items[i].name == key) return i;
	}
	return -1;
}

export function isEnumName(s: RaiserCompState, name: string): boolean {
	const prefix = name + ".";
	for (let i = 0; i < s.enumMap.items.length; i = i + 1) {
		const entryName = s.enumMap.items[i].name;
		// Check if entryName starts with prefix
		if (entryName.length > prefix.length) {
			const slice = entryName.slice(0, prefix.length);
			if (slice == prefix) return true;
		}
	}
	return false;
}

// --- Builtin helpers ---

// --- Closure pair helpers ---
// Emit a closure pair object { fn: funcIdx, env: envReg | -1 } into destReg.
// envVal = -1 sentinel means non-capturing (no env), otherwise envVal is a register holding the env.

export function emitClosurePair(s: RaiserCompState, funcIdx: int32, envReg: int32): int32 {
	const pairReg = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.NewObject, pairReg, 0, 0));
	const fnReg = allocReg(s);
	emitLoadConst(s, fnReg, raiserInt(funcIdx));
	const fnConst = addConst(s, raiserString("fn"));
	emitInst(s, raiserABC(RaiserOpcode.StoreField, pairReg, fnConst, fnReg));
	const envConst = addConst(s, raiserString("env"));
	if (envReg < 0) {
		// Non-capturing: store -1 sentinel
		const sentinelReg = allocReg(s);
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
	const cIdx = addConst(s, raiserString(message));
	emitInst(s, raiserABx(RaiserOpcode.Trap, 0, cIdx));
	const reg = allocReg(s);
	emitLoadConst(s, reg, raiserNil());
	return reg;
}

// --- Destinations ---

function writesResultAfterReading(op: RaiserOpcode): boolean {
	return match (op) {
		RaiserOpcode.LoadConst | RaiserOpcode.LoadGlobal | RaiserOpcode.LoadField | RaiserOpcode.LoadIndex
			| RaiserOpcode.AddI64 | RaiserOpcode.SubI64 | RaiserOpcode.MulI64 | RaiserOpcode.DivI64
			| RaiserOpcode.ModI64 | RaiserOpcode.NegI64
			| RaiserOpcode.AddU64 | RaiserOpcode.SubU64 | RaiserOpcode.MulU64 | RaiserOpcode.DivU64 | RaiserOpcode.ModU64
			| RaiserOpcode.AddF64 | RaiserOpcode.SubF64 | RaiserOpcode.MulF64 | RaiserOpcode.DivF64 | RaiserOpcode.NegF64
			| RaiserOpcode.BitAnd | RaiserOpcode.BitOr | RaiserOpcode.BitXor | RaiserOpcode.BitNot
			| RaiserOpcode.ShiftLeft | RaiserOpcode.ShiftRight | RaiserOpcode.ShiftRightU
			| RaiserOpcode.Conv | RaiserOpcode.ArrayLen | RaiserOpcode.StrLen | RaiserOpcode.StrCharAt
			| RaiserOpcode.IsKind => true,
		_ => false,
	};
}

function skipsInstructions(op: RaiserOpcode): boolean {
	return match (op) {
		RaiserOpcode.BeqI64 | RaiserOpcode.BneI64 | RaiserOpcode.BltI64 | RaiserOpcode.BleI64
			| RaiserOpcode.BgtI64 | RaiserOpcode.BgeI64
			| RaiserOpcode.BeqF64 | RaiserOpcode.BneF64 | RaiserOpcode.BltF64 | RaiserOpcode.BleF64
			| RaiserOpcode.BgtF64 | RaiserOpcode.BgeF64
			| RaiserOpcode.EqStr | RaiserOpcode.NeStr | RaiserOpcode.LtStr | RaiserOpcode.LeStr
			| RaiserOpcode.BltU64 | RaiserOpcode.BleU64 | RaiserOpcode.BTruthy => true,
		_ => false,
	};
}

// The code from `startPc` computed `reg` and nothing else is read of it afterwards, so the
// instruction that wrote it can write `target` instead when it is the last one, reads its operands
// before writing, and no jump of the expression lands past it (a merge of branches has several writers).
function lastWriteMayRetarget(s: RaiserCompState, startPc: int32, reg: int32): boolean {
	const end = s.code.length;
	if (end <= startPc) return false;
	const last = s.code[end - 1];
	if (last.a != reg || !writesResultAfterReading(last.op)) return false;
	for (let i = startPc; i < end - 1; i = i + 1) {
		const inst = s.code[i];
		if (inst.op == RaiserOpcode.Jump && i + 1 + getSignedAx(inst) >= end) return false;
		if (skipsInstructions(inst.op) && i + 1 + inst.c >= end) return false;
	}
	return true;
}

// `reg` is where an expression compiled from `startPc` left its value, `firstTemp` the first register
// that expression could allocate: the value is moved to `target` unless its writer can aim there.
export function landResult(s: RaiserCompState, target: number, startPc: int32, firstTemp: int32, reg: int32): void {
	if (reg == target) return;
	if (reg >= firstTemp && lastWriteMayRetarget(s, startPc, reg)) {
		s.code[s.code.length - 1].a = target;
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
		if (inst.op == RaiserOpcode.Jump && i + 1 + getSignedAx(inst) >= end) return false;
		if (skipsInstructions(inst.op) && i + 1 + inst.c >= end) return false;
		if (inst.op == RaiserOpcode.Try || inst.op == RaiserOpcode.Catch || inst.op == RaiserOpcode.Finally
			|| inst.op == RaiserOpcode.FinallyEnd) return false;
	}
	return true;
}

export function emitImplicitReturn(s: RaiserCompState): void {
	if (endIsUnreachable(s)) return;
	const nilReg = allocReg(s);
	emitLoadConst(s, nilReg, raiserNil());
	emitRet(s, nilReg);
}
