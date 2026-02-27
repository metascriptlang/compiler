// Raiser codegen — Compiler state + emit helpers
// Register allocator, constant pool builder, instruction emitter.

import {
	RaiserOpcode, RaiserInstruction,
	raiserABC, raiserABx, raiserAx
} from "../../raiser/bytecode";
import { RaiserValue, raiserInt, raiserNil, raiserBool } from "../../raiser/value";

// --- Compiler state ---

export interface RaiserCompState {
	code: RaiserInstruction[];
	constants: RaiserValue[];
	nextReg: number;
}

export function createCompState(): RaiserCompState {
	const code: RaiserInstruction[] = [];
	const constants: RaiserValue[] = [];
	return { code, constants, nextReg: 0 };
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
