// Raiser VM — Module and Function structures

import { RaiserInstruction, RaiserOpcode, raiserABC, raiserABx } from "./bytecode";
import { RaiserValue, raiserInt } from "./value";

// --- Function ---

export interface RaiserFunction {
	name: string;
	code: RaiserInstruction[];
	constants: RaiserValue[];
	arity: number;
	localsCount: number;
	maxRegs: number;
}

// --- Module ---

export interface RaiserModule {
	name: string;
	functions: RaiserFunction[];
	entry: number;
}

// --- Constructors ---

export function createRaiserFunction(name: string, code: RaiserInstruction[], constants: RaiserValue[], arity: number, localsCount: number, maxRegs: number): RaiserFunction {
	return { name, code, constants, arity, localsCount, maxRegs };
}

export function createRaiserModule(name: string, functions: RaiserFunction[], entry: number): RaiserModule {
	return { name, functions, entry };
}

// --- Test Helper ---
// Build a single-function module from raw instructions + constants.
// Used by every ops test file to avoid boilerplate.

export function makeTestModule(code: RaiserInstruction[], constants: RaiserValue[]): RaiserModule {
	const func = createRaiserFunction("test", code, constants, 0, 0, 16);
	const funcs: RaiserFunction[] = [func];
	return createRaiserModule("test", funcs, 0);
}

// --- Accessors ---
// Helper functions to access module/function internals safely.
// Function params generate pointer access (DRC workaround).

export function getFuncName(func: RaiserFunction): string {
	return func.name;
}

export function getFuncCodeLen(func: RaiserFunction): number {
	return func.code.length;
}

export function getFuncConstLen(func: RaiserFunction): number {
	return func.constants.length;
}

export function getFuncInst(func: RaiserFunction, idx: number): RaiserInstruction {
	return func.code[idx];
}

export function getFuncConst(func: RaiserFunction, idx: number): RaiserValue {
	return func.constants[idx];
}

export function getModuleFunc(mod: RaiserModule, idx: number): RaiserFunction {
	return mod.functions[idx];
}

export function getModuleEntry(mod: RaiserModule): RaiserFunction {
	const idx = mod.entry;
	return mod.functions[idx];
}

// --- Tests ---
test "create function" {
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [];
	const func = createRaiserFunction("main", code, consts, 0, 0, 4);
	assert getFuncName(func) == "main";
	assert getFuncCodeLen(func) == 1;
	assert getFuncConstLen(func) == 0;
	assert func.arity == 0;
	assert func.maxRegs == 4;
}

test "function with constants" {
	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [raiserInt(42)];
	const func = createRaiserFunction("f", code, consts, 0, 1, 4);
	assert getFuncCodeLen(func) == 2;
	assert getFuncConstLen(func) == 1;
	const c0 = getFuncConst(func, 0);
	assert c0.intVal == 42;
}

test "create module" {
	const mod = makeTestModule(
		[raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
		[]
	);
	assert mod.name == "test";
	assert mod.functions.length == 1;
	assert mod.entry == 0;
}

test "module entry function" {
	const mod = makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(99)]
	);
	const entry = getModuleEntry(mod);
	assert getFuncName(entry) == "test";
	assert getFuncCodeLen(entry) == 2;
	const inst0 = getFuncInst(entry, 0);
	assert inst0.op == RaiserOpcode.LoadConst;
}
