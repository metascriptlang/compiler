// Raiser VM — Module and Function structures

import { RaiserInstruction, RaiserOpcode, RaiserRegClass, raiserABC, raiserABx, packInstruction, inRefFile } from "./bytecode";
import { RaiserValue, RaiserValueKind, RaiserClassType, raiserInt, constStringText } from "./value";
import { RaiserCopyPlan } from "./valueCopy";
import { layoutRegisters } from "./regs";

// --- Function ---

export interface RaiserFunction {
	name: string;
	code: RaiserInstruction[];  // registers renumbered into ranks; disasm and tests read it, the VM reads `packed`
	packed: int64[];      // code, packed once by createRaiserFunction
	lines: int32[];       // source line per instruction, 0 = unknown
	fieldCache: int32[];  // LoadField/StoreField cached field index per instruction, -1 = miss
	constants: RaiserValue[];
	names: string[];      // constants[i] read as text, "" for a non-string; LoadField and StoreField compare it on every access
	arity: number;
	localsCount: number;
	wordRegs: int32;      // registers of the word file the frame holds
	refRegs: int32;       // registers of the ref file the frame holds
	paramRefs: int32;     // the leading ref registers that hold its parameters, which are the caller's argument registers
	regClasses: RaiserRegClass[];   // class of each register in the numbering the function was built with
	regOps: int32[];      // the tagged operand of each of those registers
	blocks: int64[];      // site table: word start, ref start, argument count, class signature, then a tagged operand per argument
	sigs: int64[];        // sigs[n] is the class signature of the first n registers
	copyPlans: RaiserCopyPlan[];
	classTypes: RaiserClassType[];
}

export function assertPacked(func: RaiserFunction): void {
	if (func.packed.length != func.code.length) {
		throw new Error(`internal: function ${func.name} has ${func.code.length} instructions but ${func.packed.length} packed words; its code changed after createRaiserFunction`);
	}
}

// --- Module ---

export interface RaiserModuleRecord {
	name: string;
	init: number;   // function index of the module body; -1 for a module initialized at startup
	requested: int32[];
	hasTLA: boolean;   // a lazy module whose body has a top-level await
}

export interface RaiserExport {
	name: string;
	funcIdx: int32;
	arity: int32;
}

export interface RaiserModule {
	name: string;
	functions: RaiserFunction[];
	entry: number;
	globalCount: int32;
	globalInit: RaiserValue[];
	records: RaiserModuleRecord[];
	exports: RaiserExport[];
}

// --- Constructors ---

export function createRaiserFunction(name: string, code: RaiserInstruction[], constants: RaiserValue[], arity: number, localsCount: number, regCount: number, classes: RaiserRegClass[] | null = null): RaiserFunction {
	const layout = layoutRegisters(name, code, constants, regCount as int32, classes);
	const packed: int64[] = [];
	const lines: int32[] = [];
	const fieldCache: int32[] = [];
	for (const inst of layout.code) {
		packed.push(packInstruction(inst));
		lines.push(inst.line as int32);
		fieldCache.push(-1);
	}
	const names: string[] = [];
	for (const c of constants) names.push(c.kind == RaiserValueKind.String ? constStringText(c) : "");
	let paramRefs: int32 = 0;
	for (let r = 0; r < arity && r < layout.regOps.length; r += 1) if (inRefFile((layout.regOps[r] & 7) as RaiserRegClass)) paramRefs += 1;
	return { name, code: layout.code, packed, lines, fieldCache, constants, names, arity, localsCount, wordRegs: layout.wordRegs, refRegs: layout.refRegs, paramRefs, regClasses: layout.regClasses, regOps: layout.regOps, blocks: layout.blocks, sigs: layout.sigs, copyPlans: [], classTypes: [] };
}

export function createRaiserModule(name: string, functions: RaiserFunction[], entry: number): RaiserModule {
	return { name, functions, entry, globalCount: 0, globalInit: [], records: [], exports: [] };
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
	assert func.wordRegs + func.refRegs == 4;
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
