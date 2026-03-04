// Raiser VM — Bytecode executor
// Computed goto dispatch via dispatch.c, if/else fallback for Print.

@include("vm_dispatch.h")
import { raiser_dispatch_impl } from "./vm_dispatch.h";

import { check } from "std/testing";
import {
	RaiserOpcode, RaiserInstruction,
	raiserABC, raiserABx, raiserAx,
	getBx, getSignedBx, getSignedAx
} from "./bytecode";
import {
	RaiserValue, RaiserValueKind,
	raiserNil, raiserInt, raiserFloat, raiserString, raiserArray, raiserToInt, raiserToBool, raiserToString, raiserIsNil,
	RaiserArrayHeap, createArrayHeap, heapAllocArray, heapArrayGet, heapArraySet, heapArrayPush, heapArrayLen,
	RaiserObjectHeap, createObjectHeap, heapAllocObject, heapObjectGetField, heapObjectSetField,
	raiserObject
} from "./value";
import {
	RaiserModule, RaiserFunction,
	makeTestModule, getModuleEntry, getModuleFunc,
	getFuncCodeLen, getFuncInst, getFuncConst
} from "./module";

// --- VM State ---

export interface RaiserRegFile {
	slots: RaiserValue[];
}

export interface RaiserCallFrame {
	funcIdx: number;
	returnIp: number;
	returnReg: number;
	baseReg: number;
}

export interface RaiserCallFrames {
	items: RaiserCallFrame[];
}

// Field order matters — dispatch.c mirrors this struct layout exactly.
export interface RaiserVM {
	mod: RaiserModule;
	regs: RaiserRegFile;
	ip: number;
	halted: boolean;
	exitValue: RaiserValue;
	output: string;
	funcIdx: number;
	baseReg: number;
	callStack: RaiserCallFrames;
	arrayHeap: RaiserArrayHeap;
	objectHeap: RaiserObjectHeap;
}

export function createVM(mod: RaiserModule): RaiserVM {
	const slots: RaiserValue[] = [];
	for (let i = 0; i < 256; i = i + 1) {
		const nil = raiserNil();
		slots.push(nil);
	}
	const regs: RaiserRegFile = { slots };
	const nilVal = raiserNil();
	const callFrames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: callFrames };
	const arrayHeap = createArrayHeap();
	const objectHeap = createObjectHeap();
	return { mod, regs, ip: 0, halted: false, exitValue: nilVal, output: "", funcIdx: mod.entry, baseReg: 0, callStack, arrayHeap, objectHeap };
}

// --- Register access via helper functions (DRC-safe) ---

function getReg(vm: RaiserVM, idx: number): RaiserValue {
	return vm.regs.slots[idx];
}

function setReg(vm: RaiserVM, idx: number, val: RaiserValue): void {
	vm.regs.slots[idx] = val;
}

// --- Execute ---

export function execModule(mod: RaiserModule): RaiserVM {
	const vm = createVM(mod);

	while (!vm.halted) {
		const status = raiser_dispatch_impl(vm);
		if (status === 0) break;

		// C dispatch returned 1.0 — handle Print/Call/Ret in MetaScript
		const func = getModuleFunc(mod, vm.funcIdx);
		const inst = getFuncInst(func, vm.ip);
		vm.ip = vm.ip + 1;

		if (inst.op === RaiserOpcode.Print) {
			const val = getReg(vm, vm.baseReg + inst.a);
			const s = raiserToString(val);
			vm.output = vm.output + s + "\n";
		} else if (inst.op === RaiserOpcode.Call) {
			vmHandleCall(vm, inst);
		} else if (inst.op === RaiserOpcode.CallIndirect) {
			vmHandleCallIndirect(vm, inst);
		} else if (inst.op === RaiserOpcode.Ret) {
			vmHandleRet(vm, inst);
		} else if (inst.op === RaiserOpcode.NewArray) {
			vmHandleNewArray(vm, inst);
		} else if (inst.op === RaiserOpcode.LoadIndex) {
			vmHandleLoadIndex(vm, inst);
		} else if (inst.op === RaiserOpcode.StoreIndex) {
			vmHandleStoreIndex(vm, inst);
		} else if (inst.op === RaiserOpcode.ArrayLen) {
			vmHandleArrayLen(vm, inst);
		} else if (inst.op === RaiserOpcode.ArrayPush) {
			vmHandleArrayPush(vm, inst);
		} else if (inst.op === RaiserOpcode.NewObject) {
			vmHandleNewObject(vm, inst);
		} else if (inst.op === RaiserOpcode.LoadField) {
			vmHandleLoadField(vm, mod, inst);
		} else if (inst.op === RaiserOpcode.StoreField) {
			vmHandleStoreField(vm, mod, inst);
		} else if (inst.op === RaiserOpcode.ConcatStr) {
			vmHandleConcatStr(vm, inst);
		} else if (inst.op === RaiserOpcode.EqStr) {
			vmHandleEqStr(vm, inst);
		} else if (inst.op === RaiserOpcode.NeStr) {
			vmHandleNeStr(vm, inst);
		} else if (inst.op === RaiserOpcode.StrLen) {
			vmHandleStrLen(vm, inst);
		} else if (inst.op === RaiserOpcode.StrCharAt) {
			vmHandleStrCharAt(vm, inst);
		} else if (inst.op === RaiserOpcode.StrSlice) {
			vmHandleStrSlice(vm, inst);
		} else if (inst.op === RaiserOpcode.AddF64) {
			vmHandleAddF64(vm, inst);
		} else if (inst.op === RaiserOpcode.SubF64) {
			vmHandleSubF64(vm, inst);
		} else if (inst.op === RaiserOpcode.MulF64) {
			vmHandleMulF64(vm, inst);
		} else if (inst.op === RaiserOpcode.DivF64) {
			vmHandleDivF64(vm, inst);
		} else if (inst.op === RaiserOpcode.NegF64) {
			vmHandleNegF64(vm, inst);
		} else if (inst.op === RaiserOpcode.BeqF64) {
			vmHandleBeqF64(vm, inst);
		} else if (inst.op === RaiserOpcode.BneF64) {
			vmHandleBneF64(vm, inst);
		} else if (inst.op === RaiserOpcode.BltF64) {
			vmHandleBltF64(vm, inst);
		} else if (inst.op === RaiserOpcode.BleF64) {
			vmHandleBleF64(vm, inst);
		} else if (inst.op === RaiserOpcode.BgtF64) {
			vmHandleBgtF64(vm, inst);
		} else if (inst.op === RaiserOpcode.BgeF64) {
			vmHandleBgeF64(vm, inst);
		} else {
			vm.halted = true;
		}
	}

	return vm;
}

// --- Call/Ret handlers ---

function vmHandleCall(vm: RaiserVM, inst: RaiserInstruction): void {
	const destReg = inst.a;
	const calleeFuncIdx = inst.b;
	const argCount = inst.c;

	// Push caller's frame
	const frame: RaiserCallFrame = {
		funcIdx: vm.funcIdx,
		returnIp: vm.ip,
		returnReg: vm.baseReg + destReg,
		baseReg: vm.baseReg,
	};
	vm.callStack.items.push(frame);

	// Callee's base = right at args (R[dest+1..dest+N] become callee's R[0..N-1])
	vm.baseReg = vm.baseReg + destReg + 1;
	vm.funcIdx = calleeFuncIdx;
	vm.ip = 0;
}

function vmHandleRet(vm: RaiserVM, inst: RaiserInstruction): void {
	if (vm.callStack.items.length === 0) {
		// Top-level return — halt
		const retVal = getReg(vm, vm.baseReg + inst.a);
		vm.exitValue.kind = retVal.kind;
		vm.exitValue.intVal = retVal.intVal;
		vm.exitValue.floatVal = retVal.floatVal;
		vm.exitValue.strVal = retVal.strVal;
		vm.halted = true;
		return;
	}

	// Pop frame
	const len = vm.callStack.items.length;
	const frame = vm.callStack.items[len - 1];
	vm.callStack.items.length = len - 1;

	// Deep-copy return value to caller's dest register
	// (pointer alias via setReg would let subsequent calls corrupt the value)
	const srcVal = getReg(vm, vm.baseReg + inst.a);
	const dstVal = getReg(vm, frame.returnReg);
	dstVal.kind = srcVal.kind;
	dstVal.intVal = srcVal.intVal;
	dstVal.floatVal = srcVal.floatVal;
	dstVal.strVal = srcVal.strVal;

	// Restore caller state
	vm.funcIdx = frame.funcIdx;
	vm.baseReg = frame.baseReg;
	vm.ip = frame.returnIp;
}

function vmHandleCallIndirect(vm: RaiserVM, inst: RaiserInstruction): void {
	const destReg = inst.a;
	const funcIdxReg = getReg(vm, vm.baseReg + inst.b);
	const calleeFuncIdx = funcIdxReg.intVal;
	const argCount = inst.c;

	// Push caller's frame
	const frame: RaiserCallFrame = {
		funcIdx: vm.funcIdx,
		returnIp: vm.ip,
		returnReg: vm.baseReg + destReg,
		baseReg: vm.baseReg,
	};
	vm.callStack.items.push(frame);

	// Callee's base = right at args (R[dest+1..dest+N] become callee's R[0..N-1])
	vm.baseReg = vm.baseReg + destReg + 1;
	vm.funcIdx = calleeFuncIdx;
	vm.ip = 0;
}

// --- Array opcode handlers ---

function vmHandleNewArray(vm: RaiserVM, inst: RaiserInstruction): void {
	const handle = heapAllocArray(vm.arrayHeap);
	const elemCount = inst.b;
	for (let i = 0; i < elemCount; i = i + 1) {
		const elem = getReg(vm, vm.baseReg + inst.a + 1 + i);
		heapArrayPush(vm.arrayHeap, handle, elem);
	}
	const arrVal = raiserArray(handle);
	setReg(vm, vm.baseReg + inst.a, arrVal);
}

function vmHandleLoadIndex(vm: RaiserVM, inst: RaiserInstruction): void {
	const arrVal = getReg(vm, vm.baseReg + inst.b);
	const idxVal = getReg(vm, vm.baseReg + inst.c);
	const handle = arrVal.intVal;
	const idx = idxVal.intVal;
	const elem = heapArrayGet(vm.arrayHeap, handle, idx);
	// Deep copy to avoid aliasing (same pattern as vmHandleRet)
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = elem.kind;
	dst.intVal = elem.intVal;
	dst.floatVal = elem.floatVal;
	dst.strVal = elem.strVal;
}

function vmHandleStoreIndex(vm: RaiserVM, inst: RaiserInstruction): void {
	const arrVal = getReg(vm, vm.baseReg + inst.a);
	const idxVal = getReg(vm, vm.baseReg + inst.b);
	const val = getReg(vm, vm.baseReg + inst.c);
	heapArraySet(vm.arrayHeap, arrVal.intVal, idxVal.intVal, val);
}

function vmHandleArrayLen(vm: RaiserVM, inst: RaiserInstruction): void {
	const arrVal = getReg(vm, vm.baseReg + inst.b);
	const len = heapArrayLen(vm.arrayHeap, arrVal.intVal);
	const result = raiserInt(len);
	setReg(vm, vm.baseReg + inst.a, result);
}

function vmHandleArrayPush(vm: RaiserVM, inst: RaiserInstruction): void {
	const arrVal = getReg(vm, vm.baseReg + inst.a);
	const val = getReg(vm, vm.baseReg + inst.b);
	heapArrayPush(vm.arrayHeap, arrVal.intVal, val);
}

// --- Object opcode handlers ---

function vmHandleNewObject(vm: RaiserVM, inst: RaiserInstruction): void {
	const handle = heapAllocObject(vm.objectHeap);
	const objVal = raiserObject(handle);
	setReg(vm, vm.baseReg + inst.a, objVal);
}

function vmHandleLoadField(vm: RaiserVM, mod: RaiserModule, inst: RaiserInstruction): void {
	const objVal = getReg(vm, vm.baseReg + inst.b);
	const func = getModuleFunc(mod, vm.funcIdx);
	const nameVal = getFuncConst(func, inst.c);
	const fieldName = nameVal.strVal;
	const elem = heapObjectGetField(vm.objectHeap, objVal.intVal, fieldName);
	// Deep copy to avoid aliasing
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = elem.kind;
	dst.intVal = elem.intVal;
	dst.floatVal = elem.floatVal;
	dst.strVal = elem.strVal;
}

function vmHandleStoreField(vm: RaiserVM, mod: RaiserModule, inst: RaiserInstruction): void {
	const objVal = getReg(vm, vm.baseReg + inst.a);
	const func = getModuleFunc(mod, vm.funcIdx);
	const nameVal = getFuncConst(func, inst.b);
	const fieldName = nameVal.strVal;
	const val = getReg(vm, vm.baseReg + inst.c);
	heapObjectSetField(vm.objectHeap, objVal.intVal, fieldName, val);
}

// --- String opcode handlers ---

function vmHandleConcatStr(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.b);
	const rhs = getReg(vm, vm.baseReg + inst.c);
	const result = raiserToString(lhs) + raiserToString(rhs);
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = RaiserValueKind.String;
	dst.intVal = 0;
	dst.floatVal = 0.0;
	dst.strVal = result;
}

function vmHandleEqStr(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (lhs.strVal === rhs.strVal) {
		vm.ip = vm.ip + inst.c;
	}
}

function vmHandleNeStr(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (lhs.strVal !== rhs.strVal) {
		vm.ip = vm.ip + inst.c;
	}
}

// --- String method handlers ---

function vmHandleStrLen(vm: RaiserVM, inst: RaiserInstruction): void {
	const src = getReg(vm, vm.baseReg + inst.b);
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = RaiserValueKind.Int;
	dst.intVal = src.strVal.length;
	dst.floatVal = 0.0;
	dst.strVal = "";
}

function vmHandleStrCharAt(vm: RaiserVM, inst: RaiserInstruction): void {
	const src = getReg(vm, vm.baseReg + inst.b);
	const idx = getReg(vm, vm.baseReg + inst.c);
	const i = idx.intVal;
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = RaiserValueKind.String;
	dst.intVal = 0;
	dst.floatVal = 0.0;
	if (i >= 0 && i < src.strVal.length) {
		dst.strVal = src.strVal.slice(i, i + 1);
	} else {
		dst.strVal = "";
	}
}

function vmHandleStrSlice(vm: RaiserVM, inst: RaiserInstruction): void {
	const src = getReg(vm, vm.baseReg + inst.b);
	const startReg = getReg(vm, vm.baseReg + inst.c);
	const endReg = getReg(vm, vm.baseReg + inst.c + 1);
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = RaiserValueKind.String;
	dst.intVal = 0;
	dst.floatVal = 0.0;
	dst.strVal = src.strVal.slice(startReg.intVal, endReg.intVal);
}

// --- Float value extraction (handles int-to-float promotion) ---

function asNum(val: RaiserValue): number {
	if (val.kind === RaiserValueKind.Float) return val.floatVal;
	return val.intVal;
}

// --- Float arithmetic handlers ---

function vmHandleAddF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.b);
	const rhs = getReg(vm, vm.baseReg + inst.c);
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) + asNum(rhs);
	dst.intVal = 0;
	dst.strVal = "";
}

function vmHandleSubF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.b);
	const rhs = getReg(vm, vm.baseReg + inst.c);
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) - asNum(rhs);
	dst.intVal = 0;
	dst.strVal = "";
}

function vmHandleMulF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.b);
	const rhs = getReg(vm, vm.baseReg + inst.c);
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) * asNum(rhs);
	dst.intVal = 0;
	dst.strVal = "";
}

function vmHandleDivF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.b);
	const rhs = getReg(vm, vm.baseReg + inst.c);
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = RaiserValueKind.Float;
	const rv = asNum(rhs);
	if (rv !== 0.0) {
		dst.floatVal = asNum(lhs) / rv;
	} else {
		dst.floatVal = 0.0;
	}
	dst.intVal = 0;
	dst.strVal = "";
}

function vmHandleNegF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const src = getReg(vm, vm.baseReg + inst.b);
	const dst = getReg(vm, vm.baseReg + inst.a);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = 0.0 - asNum(src);
	dst.intVal = 0;
	dst.strVal = "";
}

// --- Float compare-branch handlers ---

function vmHandleBeqF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (asNum(lhs) === asNum(rhs)) { vm.ip = vm.ip + inst.c; }
}

function vmHandleBneF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (asNum(lhs) !== asNum(rhs)) { vm.ip = vm.ip + inst.c; }
}

function vmHandleBltF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (asNum(lhs) < asNum(rhs)) { vm.ip = vm.ip + inst.c; }
}

function vmHandleBleF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (asNum(lhs) <= asNum(rhs)) { vm.ip = vm.ip + inst.c; }
}

function vmHandleBgtF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (asNum(lhs) > asNum(rhs)) { vm.ip = vm.ip + inst.c; }
}

function vmHandleBgeF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (asNum(lhs) >= asNum(rhs)) { vm.ip = vm.ip + inst.c; }
}

// --- Bitwise handlers ---

// Bitwise ops are handled entirely in C dispatch (vm_dispatch.c)
// using int64_t casts — MetaScript fallback not needed.

// --- Test helpers ---

function execBinOp(op: RaiserOpcode, a: number, b: number): RaiserVM {
	return execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABC(op, 2, 0, 1),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(a), raiserInt(b)]
	));
}

// --- Tests ---
test "halt returns constant" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(42)]
	));
	check(vm.exitValue.intVal === 42);
}

test "add: 10 + 20 = 30" { check(execBinOp(RaiserOpcode.AddI64, 10, 20).exitValue.intVal === 30); }

test "sub: 100 - 42 = 58" { check(execBinOp(RaiserOpcode.SubI64, 100, 42).exitValue.intVal === 58); }

test "mul: 6 * 7 = 42" { check(execBinOp(RaiserOpcode.MulI64, 6, 7).exitValue.intVal === 42); }

test "div: 84 / 2 = 42" { check(execBinOp(RaiserOpcode.DivI64, 84, 2).exitValue.intVal === 42); }

test "mod: 17 % 5 = 2" { check(execBinOp(RaiserOpcode.ModI64, 17, 5).exitValue.intVal === 2); }

test "neg: -(7) = -7" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.NegI64, 1, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(7)]
	));
	check(vm.exitValue.intVal === -7);
}

test "chained: (2 + 3) * 4 = 20" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
			raiserABx(RaiserOpcode.LoadConst, 3, 2),
			raiserABC(RaiserOpcode.MulI64, 4, 2, 3),
			raiserABC(RaiserOpcode.Halt, 4, 0, 0),
		],
		[raiserInt(2), raiserInt(3), raiserInt(4)]
	));
	check(vm.exitValue.intVal === 20);
}

test "print captures output" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Print, 0, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(42)]
	));
	check(vm.output === "42\n");
}

test "bgt: 10 > 5 → true branch" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),     // R0 = 10
			raiserABx(RaiserOpcode.LoadConst, 1, 1),     // R1 = 5
			raiserABC(RaiserOpcode.BgtI64, 0, 1, 1),     // if R0 > R1 skip 1
			raiserAx(RaiserOpcode.Jump, 2),               // else jump +2
			raiserABx(RaiserOpcode.LoadConst, 2, 2),     // true: R2 = 1
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 3),     // false: R2 = 0
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(10), raiserInt(5), raiserInt(1), raiserInt(0)]
	));
	check(vm.exitValue.intVal === 1);
}

test "bgt: 3 > 5 → false branch" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABC(RaiserOpcode.BgtI64, 0, 1, 1),
			raiserAx(RaiserOpcode.Jump, 2),
			raiserABx(RaiserOpcode.LoadConst, 2, 2),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 3),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(3), raiserInt(5), raiserInt(1), raiserInt(0)]
	));
	check(vm.exitValue.intVal === 0);
}

test "loop: sum 1..5 = 15" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),     // 0: R0 = 0 (sum)
			raiserABx(RaiserOpcode.LoadConst, 1, 1),     // 1: R1 = 1 (i)
			raiserABx(RaiserOpcode.LoadConst, 2, 2),     // 2: R2 = 5 (limit)
			raiserABx(RaiserOpcode.LoadConst, 3, 1),     // 3: R3 = 1 (incr)
			raiserABC(RaiserOpcode.BgtI64, 1, 2, 3),     // 4: if i > limit skip 3 → halt
			raiserABC(RaiserOpcode.AddI64, 0, 0, 1),     // 5: sum += i
			raiserABC(RaiserOpcode.AddI64, 1, 1, 3),     // 6: i += 1
			raiserAx(RaiserOpcode.Jump, -4),              // 7: back to cmp (ip=8-4=4)
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),       // 8: halt
		],
		[raiserInt(0), raiserInt(1), raiserInt(5)]
	));
	check(vm.exitValue.intVal === 15);
}

test "beq: equal values" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABC(RaiserOpcode.BeqI64, 0, 1, 1),     // if R0 == R1 skip 1
			raiserAx(RaiserOpcode.Jump, 1),
			raiserABx(RaiserOpcode.LoadConst, 2, 1),     // R2 = 1 (equal)
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(7), raiserInt(1)]
	));
	check(vm.exitValue.intVal === 1);
}

test "NewArray empty" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),   // R0 = []
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[]
	));
	check(vm.exitValue.kind === RaiserValueKind.Array);
}

test "NewArray with elements + LoadIndex" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 1, 0),     // R1 = 10
			raiserABx(RaiserOpcode.LoadConst, 2, 1),     // R2 = 20
			raiserABC(RaiserOpcode.NewArray, 0, 2, 0),   // R0 = [R1, R2] = [10, 20]
			raiserABx(RaiserOpcode.LoadConst, 3, 2),     // R3 = 1 (index)
			raiserABC(RaiserOpcode.LoadIndex, 4, 0, 3),  // R4 = R0[1] = 20
			raiserABC(RaiserOpcode.Halt, 4, 0, 0),
		],
		[raiserInt(10), raiserInt(20), raiserInt(1)]
	));
	check(vm.exitValue.intVal === 20);
}

test "ArrayLen" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 1),
			raiserABx(RaiserOpcode.LoadConst, 3, 2),
			raiserABC(RaiserOpcode.NewArray, 0, 3, 0),   // R0 = [1, 2, 3]
			raiserABC(RaiserOpcode.ArrayLen, 4, 0, 0),   // R4 = len(R0) = 3
			raiserABC(RaiserOpcode.Halt, 4, 0, 0),
		],
		[raiserInt(1), raiserInt(2), raiserInt(3)]
	));
	check(vm.exitValue.intVal === 3);
}

test "ArrayPush + ArrayLen" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),   // R0 = []
			raiserABx(RaiserOpcode.LoadConst, 1, 0),     // R1 = 42
			raiserABC(RaiserOpcode.ArrayPush, 0, 1, 0),  // R0.push(42)
			raiserABC(RaiserOpcode.ArrayLen, 2, 0, 0),   // R2 = len(R0) = 1
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(42)]
	));
	check(vm.exitValue.intVal === 1);
}

test "StoreIndex" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 1, 0),     // R1 = 0
			raiserABC(RaiserOpcode.NewArray, 0, 1, 0),   // R0 = [0]
			raiserABx(RaiserOpcode.LoadConst, 2, 1),     // R2 = 0 (index)
			raiserABx(RaiserOpcode.LoadConst, 3, 2),     // R3 = 99 (value)
			raiserABC(RaiserOpcode.StoreIndex, 0, 2, 3), // R0[0] = 99
			raiserABC(RaiserOpcode.LoadIndex, 4, 0, 2),  // R4 = R0[0] = 99
			raiserABC(RaiserOpcode.Halt, 4, 0, 0),
		],
		[raiserInt(0), raiserInt(0), raiserInt(99)]
	));
	check(vm.exitValue.intVal === 99);
}

test "NewObject + StoreField + LoadField" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewObject, 0, 0, 0),   // R0 = {}
			raiserABx(RaiserOpcode.LoadConst, 1, 0),      // R1 = 42
			raiserABC(RaiserOpcode.StoreField, 0, 1, 1),  // R0.field(K1="x") = R1(42)
			raiserABC(RaiserOpcode.LoadField, 2, 0, 1),   // R2 = R0.field(K1="x")
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(42), raiserString("x")]
	));
	check(vm.exitValue.intVal === 42);
}

test "multiple fields" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewObject, 0, 0, 0),   // R0 = {}
			raiserABx(RaiserOpcode.LoadConst, 1, 0),      // R1 = 10
			raiserABC(RaiserOpcode.StoreField, 0, 2, 1),  // R0["x"] = 10
			raiserABx(RaiserOpcode.LoadConst, 1, 1),      // R1 = 20
			raiserABC(RaiserOpcode.StoreField, 0, 3, 1),  // R0["y"] = 20
			raiserABC(RaiserOpcode.LoadField, 2, 0, 3),   // R2 = R0["y"]
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(10), raiserInt(20), raiserString("x"), raiserString("y")]
	));
	check(vm.exitValue.intVal === 20);
}

test "field update" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewObject, 0, 0, 0),   // R0 = {}
			raiserABx(RaiserOpcode.LoadConst, 1, 0),      // R1 = 1
			raiserABC(RaiserOpcode.StoreField, 0, 2, 1),  // R0["x"] = 1
			raiserABx(RaiserOpcode.LoadConst, 1, 1),      // R1 = 99
			raiserABC(RaiserOpcode.StoreField, 0, 2, 1),  // R0["x"] = 99
			raiserABC(RaiserOpcode.LoadField, 2, 0, 2),   // R2 = R0["x"]
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(1), raiserInt(99), raiserString("x")]
	));
	check(vm.exitValue.intVal === 99);
}

test "ConcatStr: two strings" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "hello"
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = " world"
			raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),    // R2 = "hello world"
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserString("hello"), raiserString(" world")]
	));
	check(vm.exitValue.strVal === "hello world");
}

test "ConcatStr: int + string coercion" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "val: "
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = 42
			raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),    // R2 = "val: 42"
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserString("val: "), raiserInt(42)]
	));
	check(vm.exitValue.strVal === "val: 42");
}

test "EqStr: equal strings skip" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "abc"
			raiserABx(RaiserOpcode.LoadConst, 1, 0),       // R1 = "abc"
			raiserABx(RaiserOpcode.LoadConst, 2, 1),       // R2 = 1 (true)
			raiserABC(RaiserOpcode.EqStr, 0, 1, 1),        // if R0.str == R1.str skip 1
			raiserABx(RaiserOpcode.LoadConst, 2, 2),       // R2 = 0 (false)
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserString("abc"), raiserInt(1), raiserInt(0)]
	));
	check(vm.exitValue.intVal === 1);
}

test "EqStr: unequal strings no skip" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "abc"
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = "def"
			raiserABx(RaiserOpcode.LoadConst, 2, 2),       // R2 = 1 (true)
			raiserABC(RaiserOpcode.EqStr, 0, 1, 1),        // if R0.str == R1.str skip 1
			raiserABx(RaiserOpcode.LoadConst, 2, 3),       // R2 = 0 (false)
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserString("abc"), raiserString("def"), raiserInt(1), raiserInt(0)]
	));
	check(vm.exitValue.intVal === 0);
}

test "NeStr: unequal strings skip" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "abc"
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = "def"
			raiserABx(RaiserOpcode.LoadConst, 2, 2),       // R2 = 1 (true)
			raiserABC(RaiserOpcode.NeStr, 0, 1, 1),        // if R0.str != R1.str skip 1
			raiserABx(RaiserOpcode.LoadConst, 2, 3),       // R2 = 0 (false)
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserString("abc"), raiserString("def"), raiserInt(1), raiserInt(0)]
	));
	check(vm.exitValue.intVal === 1);
}

test "StrLen: string length" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "hello"
			raiserABC(RaiserOpcode.StrLen, 1, 0, 0),       // R1 = len("hello") = 5
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserString("hello")]
	));
	check(vm.exitValue.intVal === 5);
}

test "StrCharAt: get character" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "hello"
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = 1
			raiserABC(RaiserOpcode.StrCharAt, 2, 0, 1),    // R2 = "e"
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserString("hello"), raiserInt(1)]
	));
	check(vm.exitValue.strVal === "e");
}

test "StrSlice: substring" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "hello world"
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = 0 (start)
			raiserABx(RaiserOpcode.LoadConst, 2, 2),       // R2 = 5 (end, at C+1)
			raiserABC(RaiserOpcode.StrSlice, 3, 0, 1),     // R3 = slice(R0, R1, R2)
			raiserABC(RaiserOpcode.Halt, 3, 0, 0),
		],
		[raiserString("hello world"), raiserInt(0), raiserInt(5)]
	));
	check(vm.exitValue.strVal === "hello");
}

test "StrLen: empty string" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.StrLen, 1, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserString("")]
	));
	check(vm.exitValue.intVal === 0);
}

test "CallIndirect basic" {
	// func0: return 42
	// entry: R0 = funcIdx(0), CallIndirect R1 R0 0 → R1 = func0() = 42
	const func0Code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),  // R0 = 42
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const func0Consts: RaiserValue[] = [raiserInt(42)];
	const f0 = createRaiserFunction("func0", func0Code, func0Consts, 0, 0, 2);

	const entryCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),  // R0 = 0 (funcIdx of func0)
		raiserABC(RaiserOpcode.CallIndirect, 1, 0, 0),  // R1 = call func[R0]()
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	];
	const entryConsts: RaiserValue[] = [raiserInt(0)];
	const entry = createRaiserFunction("main", entryCode, entryConsts, 0, 0, 4);

	const funcs: RaiserFunction[] = [f0, entry];
	const mod = createRaiserModule("test", funcs, 1);
	const vm = execModule(mod);
	check(vm.exitValue.intVal === 42);
}

test "CallIndirect with args" {
	// func0(a, b): return a + b
	// entry: R0 = funcIdx(0), R2 = 10, R3 = 20, CallIndirect R1 R0 2 → R1 = func0(10,20) = 30
	const func0Code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.AddI64, 2, 0, 1),  // R2 = R0 + R1
		raiserABC(RaiserOpcode.Ret, 2, 0, 0),
	];
	const func0Consts: RaiserValue[] = [];
	const f0 = createRaiserFunction("add", func0Code, func0Consts, 2, 0, 4);

	const entryCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),  // R0 = 0 (funcIdx)
		raiserABx(RaiserOpcode.LoadConst, 2, 1),  // R2 = 10 (arg1 at dest+1)
		raiserABx(RaiserOpcode.LoadConst, 3, 2),  // R3 = 20 (arg2 at dest+2)
		raiserABC(RaiserOpcode.CallIndirect, 1, 0, 2),  // R1 = call func[R0](R2, R3)
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	];
	const entryConsts: RaiserValue[] = [raiserInt(0), raiserInt(10), raiserInt(20)];
	const entry = createRaiserFunction("main", entryCode, entryConsts, 0, 0, 6);

	const funcs: RaiserFunction[] = [f0, entry];
	const mod = createRaiserModule("test", funcs, 1);
	const vm = execModule(mod);
	check(vm.exitValue.intVal === 30);
}

test "CallIndirect return value" {
	// func0(): return 7
	// entry: call func0 via indirect, multiply result by 6
	const func0Code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const func0Consts: RaiserValue[] = [raiserInt(7)];
	const f0 = createRaiserFunction("seven", func0Code, func0Consts, 0, 0, 2);

	const entryCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),  // R0 = 0 (funcIdx)
		raiserABC(RaiserOpcode.CallIndirect, 1, 0, 0),  // R1 = call func[R0]() = 7
		raiserABx(RaiserOpcode.LoadConst, 2, 1),  // R2 = 6
		raiserABC(RaiserOpcode.MulI64, 3, 1, 2),  // R3 = R1 * R2 = 42
		raiserABC(RaiserOpcode.Halt, 3, 0, 0),
	];
	const entryConsts: RaiserValue[] = [raiserInt(0), raiserInt(6)];
	const entry = createRaiserFunction("main", entryCode, entryConsts, 0, 0, 6);

	const funcs: RaiserFunction[] = [f0, entry];
	const mod = createRaiserModule("test", funcs, 1);
	const vm = execModule(mod);
	check(vm.exitValue.intVal === 42);
}

test "two objects bidirectional link in function" {
	// mk(n): NewObj R1, NewObj R2, Store R2."ref"=R1, Store R1."get"=R2, Store R1."n"=R0, Ret R1
	// entry: LoadConst R2 5, Move R1 R2, Call R0 mk 1, LoadField R1 R0 "n", Halt R1
	const mkCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.NewObject, 1, 0, 0),       // R1 = {} (self)
		raiserABC(RaiserOpcode.NewObject, 2, 0, 0),       // R2 = {} (cl)
		raiserABC(RaiserOpcode.StoreField, 2, 0, 1),      // cl."ref" = self
		raiserABC(RaiserOpcode.StoreField, 1, 1, 2),      // self."get" = cl
		raiserABC(RaiserOpcode.StoreField, 1, 2, 0),      // self."n" = n
		raiserABC(RaiserOpcode.Ret, 1, 0, 0),
	];
	const mkConsts: RaiserValue[] = [raiserString("ref"), raiserString("get"), raiserString("n")];
	const mk = createRaiserFunction("mk", mkCode, mkConsts, 1, 0, 3);

	const entryCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 2, 0),          // R2 = 5
		raiserABC(RaiserOpcode.Move, 1, 2, 0),            // R1 = R2
		raiserABC(RaiserOpcode.Call, 0, 0, 1),             // R0 = mk(R1=5)
		raiserABC(RaiserOpcode.LoadField, 1, 0, 1),       // R1 = R0."n"
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	];
	const entryConsts: RaiserValue[] = [raiserInt(5), raiserString("n")];
	const entry = createRaiserFunction("main", entryCode, entryConsts, 0, 0, 4);

	const funcs: RaiserFunction[] = [mk, entry];
	const mod = createRaiserModule("test", funcs, 1);
	const vm = execModule(mod);
	check(vm.exitValue.intVal === 5);
}
