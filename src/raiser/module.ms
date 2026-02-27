// Raiser VM — Module and Function structures
// DRC-safe: all arrays wrapped in interfaces.

import { test, check, testGroup } from "std/testing";
import { RaiserInstruction, RaiserOpcode, raiserABC, raiserABx } from "./bytecode";
import { RaiserValue, RaiserValueKind, raiserInt, raiserNil } from "./value";

// --- DRC-safe wrappers ---

export interface RaiserCodeBuf {
	items: RaiserInstruction[];
}

export interface RaiserConstPool {
	values: RaiserValue[];
}

// --- Function ---

export interface RaiserFunction {
	name: string;
	code: RaiserCodeBuf;
	constants: RaiserConstPool;
	arity: number;
	localsCount: number;
	maxRegs: number;
}

export interface RaiserFunctionList {
	items: RaiserFunction[];
}

// --- Module ---

export interface RaiserModule {
	name: string;
	functions: RaiserFunctionList;
	entry: number;
}

// --- Constructors ---

export function createRaiserFunction(name: string, code: RaiserInstruction[], constants: RaiserValue[], arity: number, localsCount: number, maxRegs: number): RaiserFunction {
	const codeBuf: RaiserCodeBuf = { items: code };
	const constPool: RaiserConstPool = { values: constants };
	return { name, code: codeBuf, constants: constPool, arity, localsCount, maxRegs };
}

export function createRaiserModule(name: string, functions: RaiserFunction[], entry: number): RaiserModule {
	const funcList: RaiserFunctionList = { items: functions };
	return { name, functions: funcList, entry };
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
// Function params generate pointer access (DRC workaround #15).

export function getFuncName(func: RaiserFunction): string {
	return func.name;
}

export function getFuncCodeLen(func: RaiserFunction): number {
	return func.code.items.length;
}

export function getFuncConstLen(func: RaiserFunction): number {
	return func.constants.values.length;
}

export function getFuncInst(func: RaiserFunction, idx: number): RaiserInstruction {
	return func.code.items[idx];
}

export function getFuncConst(func: RaiserFunction, idx: number): RaiserValue {
	return func.constants.values[idx];
}

export function getModuleFunc(mod: RaiserModule, idx: number): RaiserFunction {
	return mod.functions.items[idx];
}

export function getModuleEntry(mod: RaiserModule): RaiserFunction {
	const idx = mod.entry;
	return mod.functions.items[idx];
}

// --- Tests ---

testGroup("RaiserFunction", () => {
	test("create function", () => {
		const code: RaiserInstruction[] = [
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		];
		const consts: RaiserValue[] = [];
		const func = createRaiserFunction("main", code, consts, 0, 0, 4);
		check(getFuncName(func) === "main");
		check(getFuncCodeLen(func) === 1);
		check(getFuncConstLen(func) === 0);
		check(func.arity === 0);
		check(func.maxRegs === 4);
	});

	test("function with constants", () => {
		const code: RaiserInstruction[] = [
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		];
		const consts: RaiserValue[] = [raiserInt(42)];
		const func = createRaiserFunction("f", code, consts, 0, 1, 4);
		check(getFuncCodeLen(func) === 2);
		check(getFuncConstLen(func) === 1);
		const c0 = getFuncConst(func, 0);
		check(c0.intVal === 42);
	});
});

testGroup("RaiserModule", () => {
	test("create module", () => {
		const mod = makeTestModule(
			[raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
			[]
		);
		check(mod.name === "test");
		check(mod.functions.items.length === 1);
		check(mod.entry === 0);
	});

	test("module entry function", () => {
		const mod = makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABC(RaiserOpcode.Halt, 0, 0, 0),
			],
			[raiserInt(99)]
		);
		const entry = getModuleEntry(mod);
		check(getFuncName(entry) === "test");
		check(getFuncCodeLen(entry) === 2);
		const inst0 = getFuncInst(entry, 0);
		check(inst0.op === RaiserOpcode.LoadConst);
	});
});
