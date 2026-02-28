// Raiser codegen — Compiler state + emit helpers
// Register allocator, constant pool builder, instruction emitter.

import {
	RaiserOpcode, RaiserInstruction,
	raiserABC, raiserABx, raiserAx
} from "../../raiser/bytecode";
import { RaiserValue, raiserInt, raiserNil, raiserBool } from "../../raiser/value";

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

// --- Compiler state ---
// Enum tracking reuses RaiserFuncMap: entries encoded as "EnumName.MemberName" → index.

export interface RaiserCompState {
	code: RaiserInstruction[];
	constants: RaiserValue[];
	nextReg: number;
	locals: RaiserLocals;
	loopStack: RaiserLoopStack;
	funcMap: RaiserFuncMap;
	enumMap: RaiserFuncMap;
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
	return { code, constants, nextReg: 0, locals, loopStack, funcMap, enumMap };
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
	return r;
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
	let i = s.locals.items.length - 1;
	while (i >= 0) {
		if (s.locals.items[i].name === name) {
			return s.locals.items[i].isString;
		}
		i = i - 1;
	}
	return false;
}

export function resolveLocal(s: RaiserCompState, name: string): number {
	let i = s.locals.items.length - 1;
	while (i >= 0) {
		if (s.locals.items[i].name === name) {
			return s.locals.items[i].reg;
		}
		i = i - 1;
	}
	return -1;
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
	const patchItems: number[] = [];
	const breakPatches: RaiserBreakPatches = { items: patchItems };
	const info: RaiserLoopInfo = { startIp, breakPatches };
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
	let i = s.funcMap.items.length - 1;
	while (i >= 0) {
		if (s.funcMap.items[i].name === name) {
			return s.funcMap.items[i].index;
		}
		i = i - 1;
	}
	return -1;
}

// --- Enum helpers ---
// Encodes enum entries as "EnumName.MemberName" → index, reusing RaiserFuncEntry.

export function declareEnum(s: RaiserCompState, enumName: string, members: string[]): void {
	let i = 0;
	while (i < members.length) {
		const key = enumName + "." + members[i];
		const entry: RaiserFuncEntry = { name: key, index: i };
		s.enumMap.items.push(entry);
		i = i + 1;
	}
}

export function resolveEnumMember(s: RaiserCompState, enumName: string, memberName: string): number {
	const key = enumName + "." + memberName;
	let i = 0;
	while (i < s.enumMap.items.length) {
		if (s.enumMap.items[i].name === key) {
			return s.enumMap.items[i].index;
		}
		i = i + 1;
	}
	return -1;
}

export function isEnumName(s: RaiserCompState, name: string): boolean {
	const prefix = name + ".";
	let i = 0;
	while (i < s.enumMap.items.length) {
		const entryName = s.enumMap.items[i].name;
		// Check if entryName starts with prefix
		if (entryName.length > prefix.length) {
			const slice = entryName.slice(0, prefix.length);
			if (slice === prefix) return true;
		}
		i = i + 1;
	}
	return false;
}
