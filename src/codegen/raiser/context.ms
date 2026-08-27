// Raiser codegen — Compiler state + emit helpers
// Register allocator, constant pool builder, instruction emitter.

import {
	RaiserOpcode, RaiserInstruction,
	raiserABC, raiserABx, raiserAx
} from "../../raiser/bytecode";
import { RaiserValue, raiserInt, raiserString } from "../../raiser/value";
import { Symbol, SymbolKind } from "../../ast/node";

// --- Locals ---

export interface RaiserLocal {
	name: string;
	reg: number;
	isString: boolean;
}

export interface RaiserLocals {
	items: RaiserLocal[];
}

// --- Loop tracking ---

export interface RaiserBreakPatches {
	items: number[];
}

export interface RaiserLoopInfo {
	startIp: number;
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
	index: number;
}

export interface RaiserFuncMap {
	items: RaiserFuncEntry[];
}

// --- Builtin registry ---
// Maps builtin function names to their function indices in the module.

export interface RaiserBuiltinEntry {
	name: string;
	funcIdx: number;
}

export interface RaiserBuiltinMap {
	items: RaiserBuiltinEntry[];
}

// --- Float register tracking ---

export interface RaiserRegFlags {
	isFloat: number[];
}

// --- Compiler state ---
// Enum tracking reuses RaiserFuncMap: entries encoded as "EnumName.MemberName" → index.

export interface RaiserCompState {
	code: RaiserInstruction[];
	constants: RaiserValue[];
	nextReg: number;
	// High-water mark of registers ever allocated. resetTemps shrinks
	// nextReg back to (max local reg + 1) between statements, so the
	// final value of nextReg reflects only the live locals, NOT the peak
	// register count needed at runtime. The VM uses this to size each
	// function's call frame — without an accurate peak, it would either
	// over-allocate (waste) or under-allocate (out-of-bounds on temp regs).
	maxRegSeen: number;
	locals: RaiserLocals;
	loopStack: RaiserLoopStack;
	funcMap: RaiserFuncMap;
	enumMap: RaiserFuncMap;
	builtins: RaiserBuiltinMap;
	regFlags: RaiserRegFlags;
}

export function createCompState(): RaiserCompState {
	const code: RaiserInstruction[] = [];
	const constants: RaiserValue[] = [];
	const localItems: RaiserLocal[] = [];
	const locals: RaiserLocals = { items: localItems };
	const loopItems: RaiserLoopInfo[] = [];
	const loopStack: RaiserLoopStack = { items: loopItems };
	const funcEntries: RaiserFuncEntry[] = [];
	const funcMap: RaiserFuncMap = { items: funcEntries };
	const enumItems: RaiserFuncEntry[] = [];
	const enumMap: RaiserFuncMap = { items: enumItems };
	const builtinItems: RaiserBuiltinEntry[] = [];
	const builtins: RaiserBuiltinMap = { items: builtinItems };
	const floatFlags: number[] = [];
	for (let i = 0; i < 256; i = i + 1) { floatFlags.push(0); }
	const regFlags: RaiserRegFlags = { isFloat: floatFlags };
	return { code, constants, nextReg: 0, maxRegSeen: 0, locals, loopStack, funcMap, enumMap, builtins, regFlags };
}

export function emitInst(s: RaiserCompState, inst: RaiserInstruction): void {
	s.code.push(inst);
}

export function addConst(s: RaiserCompState, val: RaiserValue): number {
	const idx = s.constants.length;
	s.constants.push(val);
	return idx;
}

export function allocReg(s: RaiserCompState): number {
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

export function emitLoadConst(s: RaiserCompState, reg: number, val: RaiserValue): void {
	const ci = addConst(s, val);
	const inst = raiserABx(RaiserOpcode.LoadConst, reg, ci);
	emitInst(s, inst);
}

export function emitRet(s: RaiserCompState, reg: number): void {
	emitInst(s, raiserABC(RaiserOpcode.Ret, reg, 0, 0));
}

export function emitHalt(s: RaiserCompState): void {
	emitInst(s, raiserABC(RaiserOpcode.Halt, 0, 0, 0));
}

// --- Locals helpers ---

export function declareLocal(s: RaiserCompState, name: string, reg: number): void {
	const local: RaiserLocal = { name, reg, isString: false };
	s.locals.items.push(local);
}

export function declareLocalStr(s: RaiserCompState, name: string, reg: number, isString: boolean): void {
	const local: RaiserLocal = { name, reg, isString };
	s.locals.items.push(local);
}

export function isLocalString(s: RaiserCompState, name: string): boolean {
	for (let i = s.locals.items.length - 1; i >= 0; i = i - 1) {
		if (s.locals.items[i].name === name) {
			return s.locals.items[i].isString;
		}
	}
	return false;
}

export function resolveLocal(s: RaiserCompState, name: string): number {
	for (let i = s.locals.items.length - 1; i >= 0; i = i - 1) {
		if (s.locals.items[i].name === name) {
			return s.locals.items[i].reg;
		}
	}
	return -1;
}

export function regIsFixedLocal(s: RaiserCompState, reg: number): boolean {
	for (const local of s.locals.items) {
		if (local.reg === reg) return true;
	}
	return false;
}

// --- Condition helpers ---

export function emitBranchIfFalsy(s: RaiserCompState, condReg: number): number {
	const zeroReg = allocReg(s);
	emitLoadConst(s, zeroReg, raiserInt(0));
	emitInst(s, raiserABC(RaiserOpcode.BneI64, condReg, zeroReg, 1));
	return emitJumpPlaceholder(s);
}

// --- Jump patching ---

export function emitJumpPlaceholder(s: RaiserCompState): number {
	const idx = s.code.length;
	emitInst(s, raiserAx(RaiserOpcode.Jump, 0));
	return idx;
}

export function patchJumpTo(s: RaiserCompState, idx: number, target: number): void {
	const offset = target - idx - 1;
	s.code[idx] = raiserAx(RaiserOpcode.Jump, offset);
}

export function codeLen(s: RaiserCompState): number {
	return s.code.length;
}

// --- Loop helpers ---

export function pushLoop(s: RaiserCompState, startIp: number): void {
	const info: RaiserLoopInfo = {
		startIp,
		breakPatches: { items: [] },
		continuePatches: { items: [] },
	};
	s.loopStack.items.push(info);
}

export function popLoop(s: RaiserCompState): RaiserLoopInfo {
	const len = s.loopStack.items.length;
	const info = s.loopStack.items[len - 1];
	s.loopStack.items.length = len - 1;
	return info;
}

export function currentLoop(s: RaiserCompState): RaiserLoopInfo {
	const len = s.loopStack.items.length;
	return s.loopStack.items[len - 1];
}

export function hasLoop(s: RaiserCompState): boolean {
	return s.loopStack.items.length > 0;
}

// --- Function map helpers ---

export function registerFunc(s: RaiserCompState, name: string, index: number): void {
	const entry: RaiserFuncEntry = { name, index };
	s.funcMap.items.push(entry);
}

export function resolveFunc(s: RaiserCompState, name: string): number {
	for (let i = s.funcMap.items.length - 1; i >= 0; i = i - 1) {
		if (s.funcMap.items[i].name === name) {
			return s.funcMap.items[i].index;
		}
	}
	return -1;
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
export function findEnumConstant(s: RaiserCompState, key: string): number {
	for (let i = 0; i < s.enumMap.items.length; i = i + 1) {
		if (s.enumMap.items[i].name === key) return i;
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
			if (slice === prefix) return true;
		}
	}
	return false;
}

// --- Float register helpers ---

export function markRegFloat(s: RaiserCompState, reg: number): void {
	if (reg >= 0 && reg < 256) { s.regFlags.isFloat[reg] = 1; }
}

export function isRegFloat(s: RaiserCompState, reg: number): boolean {
	if (reg >= 0 && reg < 256) { return s.regFlags.isFloat[reg] !== 0; }
	return false;
}

// --- Builtin helpers ---

export function registerBuiltin(s: RaiserCompState, name: string, funcIdx: number): void {
	const entry: RaiserBuiltinEntry = { name, funcIdx };
	s.builtins.items.push(entry);
}

export function resolveBuiltin(s: RaiserCompState, name: string): number {
	for (let i = 0; i < s.builtins.items.length; i = i + 1) {
		if (s.builtins.items[i].name === name) {
			return s.builtins.items[i].funcIdx;
		}
	}
	return -1;
}

// --- Closure pair helpers ---
// Emit a closure pair object { fn: funcIdx, env: envReg | -1 } into destReg.
// envVal = -1 sentinel means non-capturing (no env), otherwise envVal is a register holding the env.

export function emitClosurePair(s: RaiserCompState, funcIdx: number, envReg: number): number {
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

type RaiserOnDemandFn = (sym: Symbol) => number;

let _raiserOnDemandFn: RaiserOnDemandFn = (_sym: Symbol): number => {
	return -1;
};

export function registerRaiserOnDemand(fn: RaiserOnDemandFn): void {
	_raiserOnDemandFn = fn;
}

export function clearRaiserOnDemand(): void {
	_raiserOnDemandFn = (_sym: Symbol): number => {
		return -1;
	};
}

export function isRoutineSym(sym: Symbol): boolean {
	return sym.symbolKind === SymbolKind.Function
		|| sym.symbolKind === SymbolKind.Method
		|| sym.symbolKind === SymbolKind.Macro;
}

export function callRaiserOnDemand(sym: Symbol): number {
	if (!isRoutineSym(sym)) return -1;
	return _raiserOnDemandFn(sym);
}
