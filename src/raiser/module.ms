// Raiser VM — Module and Function structures

import { RaiserInstruction, RaiserOpcode, RaiserRegClass, raiserABC, raiserABx, packInstruction, inRefFile, RaiserSlotShape, RaiserCallShape, isShapedSite, SHAPED_BLOCK_SITE } from "./bytecode";
import { RaiserValue, RaiserValueKind, RaiserClassType, raiserInt, constStringText } from "./value";
import { RaiserCopyPlan } from "./valueCopy";
import { layoutRegisters } from "./regs";
import { HostEntry } from "./hostRegistry";

extern function msFloat64Bits(d: float64): int64;

// --- Function ---

export interface RaiserFunction {
	name: string;
	code: RaiserInstruction[];  // registers renumbered into ranks; disasm and tests read it, the VM reads `packed`
	packed: int64[];      // code, packed once by createRaiserFunction
	lines: int32[];       // source line per instruction, 0 = unknown
	inlined: int32[];     // inline site per instruction: 0 for the function's own code, k for inlineSites[k - 1]
	inlineSites: RaiserInlineSite[];
	fieldCache: int32[];  // LoadField/StoreField cached field index per instruction, -1 = miss
	constants: RaiserValue[];
	constWords: int64[];  // constants[i] as the word a Word, Bool or Float register holds (float bits), 0 for any other kind
	hostCache: (HostEntry | null)[];  // CallHost entry resolved once per constant index, null = not resolved yet
	nameIds: int64[];     // the interned handle of constants[i] when it is a string, -1 otherwise, so a cached field access compares integers
	names: string[];      // constants[i] read as text, "" for a non-string; a cache miss in LoadField and StoreField compares it
	arity: number;
	paramWords: int32;
	callShape: RaiserCallShape | null;
	localsCount: number;
	frameSize: int32;     // slots the frame holds: one per register, the parameters first
	ownRefs: int32[];     // the Ref and Dyn registers that are not parameters, which the frame releases and starts at zero
	regClasses: RaiserRegClass[];   // class of each register
	regOps: int32[];      // the tagged operand of each register
	blocks: int64[];      // site table: the callee's first slot, argument count, class signature, then a tagged operand per argument
	sigs: int64[];        // sigs[n] is the class signature of the first n registers
	copyPlans: RaiserCopyPlan[];
	classTypes: RaiserClassType[];
}

export interface RaiserInlineSite {
	name: string;    // the inlined routine, as its own frame is named
	parent: int32;   // the site this one was inlined into, 0 for the function itself
	callLine: int32; // the line of the call this site replaced, in its parent
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
	sinks: boolean[];
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

export function createRaiserFunction(name: string, code: RaiserInstruction[], constants: RaiserValue[], arity: number, localsCount: number, regCount: number, classes: RaiserRegClass[] | null = null, inlineSites: RaiserInlineSite[] = [], callShape: RaiserCallShape | null = null): RaiserFunction {
	validateCount(name, arity, 65535);
	validateCount(name, regCount, 65535);
	const paramWords = validateCallShape(name, callShape, arity, regCount);
	for (const inst of code) {
		if (inst.op != RaiserOpcode.LoadFieldRequired) continue;
		const index = inst.c;
		if (index != index || index < 0 || index >= constants.length ||
			index != ((index as int32) as number) ||
			constants[index as int32].kind != RaiserValueKind.String) {
			throw new Error(`internal: invalid required field name in ${name}`);
		}
	}
	const layout = layoutRegisters(name, code, constants, regCount as int32, classes);
	const packed: int64[] = [];
	const lines: int32[] = [];
	const inlined: int32[] = [];
	const fieldCache: int32[] = [];
	for (const inst of layout.code) {
		packed.push(packInstruction(inst));
		lines.push(inst.line as int32);
		inlined.push(inst.site as int32);
		fieldCache.push(-1);
	}
	const names: string[] = [];
	const hostCache: (HostEntry | null)[] = [];
	const nameIds: int64[] = [];
	const constWords: int64[] = [];
	for (const c of constants) {
		constWords.push(c.kind == RaiserValueKind.Float ? msFloat64Bits(c.floatVal) : c.kind == RaiserValueKind.Int || c.kind == RaiserValueKind.Bool ? c.intVal : 0);
		names.push(c.kind == RaiserValueKind.String ? constStringText(c) : "");
		hostCache.push(null);
		nameIds.push(c.kind == RaiserValueKind.String ? c.intVal : -1);
	}
	const ownRefs: int32[] = [];
	for (let r = paramWords; r < regCount; r += 1) if (inRefFile(layout.regClasses[r])) ownRefs.push(r);
	const func: RaiserFunction = { name, code: layout.code, packed, lines, inlined, inlineSites, fieldCache, constants, constWords, hostCache, nameIds, names, arity, paramWords, callShape, localsCount, frameSize: regCount as int32, ownRefs, regClasses: layout.regClasses, regOps: layout.regOps, blocks: layout.blocks, sigs: callShape == null ? layout.sigs : [], copyPlans: [], classTypes: [] };
	validateShapeClasses(func);
	bindReturns(func);
	return func;
}

function validateCount(name: string, value: number, limit: number): void {
	if (value != value || value < 0 || value > limit ||
		value != ((value as int32) as number)) {
		throw new Error(`internal: invalid span ABI count ${value} in ${name}`);
	}
}

function validateSlotShape(name: string, shape: RaiserSlotShape): void {
	validateCount(name, shape.words, 65535);
	if (shape.words < 1 || !shape.block && shape.words != 1) {
		throw new Error(`internal: invalid span ABI slot shape in ${name}`);
	}
}

function validateCallShape(name: string, shape: RaiserCallShape | null,
	arity: number, regCount: number): int32 {
	if (shape == null) {
		if (arity > regCount) throw new Error(`internal: parameter prefix exceeds frame in ${name}`);
		return arity as int32;
	}
	if (shape.params.length != arity) {
		throw new Error(`internal: span ABI logical arity mismatch in ${name}`);
	}
	validateSlotShape(name, shape.result);
	if (shape.result.words > regCount) throw new Error(`internal: span ABI result exceeds frame in ${name}`);
	let words: int32 = 0;
	for (const param of shape.params) {
		validateSlotShape(name, param);
		words += param.words as int32;
		if (words > regCount) throw new Error(`internal: span ABI parameter prefix exceeds frame in ${name}`);
	}
	return words;
}

function validateShapeClasses(func: RaiserFunction): void {
	const shape = func.callShape;
	if (shape == null) {
		for (const inst of func.code) {
			if (inst.op == RaiserOpcode.RetN) throw new Error(`internal: RetN requires span ABI shape in ${func.name}`);
		}
		return;
	}
	let first: int32 = 0;
	for (const param of shape.params) {
		for (let i = 0; i < param.words; i += 1) {
			if (param.block && func.regClasses[first + i] != RaiserRegClass.Word) {
				throw new Error(`internal: span ABI block parameter needs Word storage in ${func.name}`);
			}
		}
		first += param.words as int32;
	}
	for (const inst of func.code) {
		if (inst.op == RaiserOpcode.Ret && shape.result.block ||
			inst.op == RaiserOpcode.RetN && (!shape.result.block || inst.b != shape.result.words)) {
			throw new Error(`internal: span ABI return shape mismatch in ${func.name}`);
		}
	}
}

export function callSiteMatches(caller: RaiserFunction, dest: int32,
	site: int32, callee: RaiserFunction): boolean {
	const signature = caller.blocks[site + 2];
	if (!isShapedSite(signature)) return callee.callShape == null;
	const shape = callee.callShape;
	if (shape == null || (signature == SHAPED_BLOCK_SITE) != shape.result.block ||
		caller.blocks[site] - (dest >> 3) != (shape.result.words as int64) ||
		caller.blocks[site + 1] != (callee.paramWords as int64)) return false;
	for (let i = 0; i < callee.paramWords; i += 1) {
		if (((caller.blocks[site + 3 + i] as int32) & 7) != (callee.regOps[i] & 7)) return false;
	}
	return true;
}

export function createRaiserModule(name: string, functions: RaiserFunction[], entry: number): RaiserModule {
	for (const func of functions) {
		assertPacked(func);
		bindDirectCalls(func, functions);
	}
	return { name, functions, entry, globalCount: 0, globalInit: [], records: [], exports: [] };
}

function bindDirectCalls(func: RaiserFunction, functions: RaiserFunction[]): void {
	for (let pc = 0; pc < func.code.length; pc += 1) {
		const inst = func.code[pc];
		if (inst.op != RaiserOpcode.Call && inst.op != RaiserOpcode.CallDirect) continue;
		if (inst.op == RaiserOpcode.CallDirect) {
			inst.op = RaiserOpcode.Call;
			func.packed[pc] = packInstruction(inst);
		}
		if (inst.b < 0 || inst.b >= functions.length) continue;
		const callee = functions[inst.b];
		const site = inst.c as int32;
		const argc = func.blocks[site + 1];
		if (!callSiteMatches(func, inst.a as int32, site, callee)) continue;
		if (isShapedSite(func.blocks[site + 2])) continue;
		if (argc >= callee.sigs.length || callee.sigs[argc as int32] != func.blocks[site + 2]) continue;
		inst.op = RaiserOpcode.CallDirect;
		func.packed[pc] = packInstruction(inst);
	}
}

// A packed Ret carries what its frame releases: B the first register that is not a parameter, C the owned ref count times two,
// plus one when the function opens a handler and the Ret must check for one still open.
function bindReturns(func: RaiserFunction): void {
	let opensHandler: int32 = 0;
	for (const inst of func.code) {
		if (inst.op == RaiserOpcode.Try) opensHandler = 1;
	}
	const owned = func.ownRefs.length as int32;
	for (let pc = 0; pc < func.code.length; pc += 1) {
		const inst = func.code[pc];
		if (inst.op != RaiserOpcode.Ret) continue;
		func.packed[pc] = packInstruction(raiserABC(RaiserOpcode.Ret, inst.a, func.paramWords, owned * 2 + opensHandler));
	}
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
test "span ABI shape keeps logical arity and physical prefix separate" {
	const shape: RaiserCallShape = {
		params: [{ words: 1, block: false }, { words: 3, block: true }],
		result: { words: 2, block: true },
	};
	const func = createRaiserFunction("span", [
		raiserABC(RaiserOpcode.RetN, 1, 2, 0),
	], [], 2, 0, 5, [RaiserRegClass.Word, RaiserRegClass.Word,
		RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Ref],
		[], shape);
	assert func.arity == 2 && func.paramWords == 4;
	assert func.ownRefs.length == 1 && func.ownRefs[0] == 4;
}

function spanShapeRefusal(shape: RaiserCallShape, arity: number,
	classes: RaiserRegClass[]): string {
	try {
		createRaiserFunction("badSpan", [], [], arity, 0,
			classes.length, classes, [], shape);
	} catch (e) { return e.message; }
	return "";
}

test "span ABI validates shape counts before narrowing in every mode" {
	for (const words of [0, -1, 1.5, NaN, Infinity, -Infinity, 65536]) {
		const error = spanShapeRefusal({
			params: [{ words, block: true }],
			result: { words: 1, block: true },
		}, 1, [RaiserRegClass.Word]);
		assert error.includes("span ABI"), `${words}: ${error}`;
	}
}

test "span ABI rejects arity scalar extent block class and frame overflow" {
	const block: RaiserSlotShape = { words: 2, block: true };
	const scalar: RaiserSlotShape = { words: 1, block: false };
	assert spanShapeRefusal({ params: [block], result: scalar }, 2,
		[RaiserRegClass.Word, RaiserRegClass.Word]).includes("arity");
	assert spanShapeRefusal({ params: [{ words: 2, block: false }], result: scalar },
		1, [RaiserRegClass.Word, RaiserRegClass.Word]).includes("slot shape");
	assert spanShapeRefusal({ params: [block], result: scalar }, 1,
		[RaiserRegClass.Word]).includes("prefix");
	assert spanShapeRefusal({ params: [scalar], result: block }, 1,
		[RaiserRegClass.Word]).includes("result exceeds");
	assert spanShapeRefusal({ params: [block], result: scalar }, 1,
		[RaiserRegClass.Word, RaiserRegClass.Ref]).includes("Word storage");
}

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
	assert func.frameSize == 4;
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
	assert inst0.op == RaiserOpcode.LoadConstW;
}
