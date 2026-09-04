// Raiser VM — Bytecode executor
// If/else dispatch loop. C backend has optional computed-goto fast path (vmDispatch.c).

import {
	RaiserOpcode, RaiserInstruction,
	raiserABC, raiserABx, raiserAx,
	getBx, getSignedAx
} from "./bytecode";
import {
	RaiserValue, RaiserValueKind,
	raiserNil, raiserInt, raiserBool, raiserString, raiserArray, raiserToString, copyValueInto,
	RaiserArrayHeap, createArrayHeap, heapAllocArray, heapArrayGet, heapArraySet, heapArrayPush, heapArrayLen,
	RaiserObjectHeap, RaiserObjectField, createStructHeap, heapAllocObject, raiserObject,
	rcIncref, rcDecref
} from "./value";
import {
	RaiserModule, RaiserFunction,
	makeTestModule, getFuncConst, getFuncConstLen, getFuncInst, getModuleFunc, createRaiserFunction, createRaiserModule,
} from "./module";
import { orcCollectCycles } from "./orc";
import { lookupHostFn, registerHostFn, _resetHostRegistryForTests, setActiveHostHeaps, activeHostObjectHeap, activeHostArrayHeap } from "./hostRegistry";
import { RaiserHostFn } from "./marshal";

// --- VM State ---

export interface RaiserRegFile {
	slots: RaiserValue[];
}

export interface RaiserCallFrame {
	funcIdx: number;
	returnIp: number;
	returnReg: number;
	baseReg: number;
	funcName: string;
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
	loopCount: number;   // backward jumps (loop iterations) since the last entry reset
	loopLimit: number;   // max loop iterations before the VM refuses (reference: maxLoopIterationsVM)
	error: string;    // Non-empty when VM stopped due to error
	gcMode: string;   // "arena" (default, no RC) | "orc" (refcount + cycle collector)
	gcThreshold: number;  // live-object count that triggers a cycle collection (orc)
}

// Initial register file size. The slots array grows on demand via
// `ensureSlots` at function-call entry — this constant only sets the
// starting capacity to avoid most early reallocations. NOT a hard cap.
const RAISER_INITIAL_SLOTS = 256;

// Grow the register file to hold at least `count` slots. Pads new slots
// with fresh nil values so direct indexing (`slots[i]`) is always safe up
// to the high-water mark. Called at every function-call entry with
// `baseReg + callee.maxRegs` so the callee's frame is fully reserved
// before any opcode in it accesses a register.
export function ensureSlots(regs: RaiserRegFile, count: number): void {
	while (regs.slots.length < count) {
		regs.slots.push(raiserNil());
	}
}

// Default iteration budget. The unit is the BACKWARD JUMP (loop back-edge),
// not the raw instruction — same unit the reference VM budgets
// (maxLoopIterationsVM); recursion has its own guard (MAX_CALL_DEPTH here,
// maxCallDepthVM there), and straight-line code is finite by construction.
// A per-instruction budget penalized MS-implemented std by the loop BODY
// length: identical comptime startsWith folded or blew the budget depending
// on which tier supplied it (15x measured, 2026-09-04). CLI override:
// --max-vm-iterations=<n> (options.ms calls setDefaultLoopLimit).
const DEFAULT_LOOP_LIMIT = 10000000;
let vmLoopLimitDefault: number = DEFAULT_LOOP_LIMIT;

export function setDefaultLoopLimit(n: number): void {
	if (n > 0) vmLoopLimitDefault = n;
}

export function createVM(mod: RaiserModule, gcMode: string = "arena"): RaiserVM {
	const slots: RaiserValue[] = [];
	const regs: RaiserRegFile = { slots };
	// Reserve the entry function's frame up-front (and at least the initial
	// capacity) so the entry's first opcode can write to its locals without
	// hitting an empty register file.
	const entryFunc = getModuleFunc(mod, mod.entry);
	const entryReserve = entryFunc.maxRegs > RAISER_INITIAL_SLOTS ? entryFunc.maxRegs : RAISER_INITIAL_SLOTS;
	ensureSlots(regs, entryReserve);
	const nilVal = raiserNil();
	const callFrames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: callFrames };
	const arrayHeap = createArrayHeap();
	const objectHeap = createStructHeap();
	return { mod, regs, ip: 0, halted: false, exitValue: nilVal, output: "", funcIdx: mod.entry, baseReg: 0, callStack, arrayHeap, objectHeap, loopCount: 0, loopLimit: vmLoopLimitDefault, error: "", gcMode, gcThreshold: 256 };
}

// --- Register access via helper functions (DRC-safe) ---

// Slot accessors. Pre-condition: every Call/CallIndirect calls
// ensureSlots(regs, baseReg + callee.maxRegs) before transferring control,
// so any in-frame reg access fits in the array. A defensive grow here
// guards against codegen bugs (e.g. a function whose maxRegs metadata
// underestimates its actual usage) — better to allocate one nil than
// crash with a low-level array bounds error from the runtime.
function getReg(vm: RaiserVM, idx: number): RaiserValue {
	if (idx >= vm.regs.slots.length) ensureSlots(vm.regs, idx + 1);
	return vm.regs.slots[idx];
}

// --- ORC refcount helpers (gated on gcMode; no-op in arena mode) ---

function vmIncref(vm: RaiserVM, val: RaiserValue): void {
	if (vm.gcMode === "orc") rcIncref(vm.arrayHeap, vm.objectHeap, val);
}

function vmDecref(vm: RaiserVM, val: RaiserValue): void {
	if (vm.gcMode === "orc") rcDecref(vm.arrayHeap, vm.objectHeap, val);
}

// Adaptive cycle collection: when the live (allocated minus recycled) heap object
// count outgrows the threshold, run a collection. ARC keeps acyclic workloads
// below threshold; only cyclic garbage makes `live` climb, which the collector
// reclaims — so the threshold tracks the true live set rather than thrashing.
function vmLiveCount(vm: RaiserVM): number {
	return (vm.objectHeap.objects.length - vm.objectHeap.freeList.length)
		+ (vm.arrayHeap.arrays.length - vm.arrayHeap.freeList.length);
}

function vmMaybeCollect(vm: RaiserVM): void {
	if (vm.gcMode !== "orc") return;
	if (vmLiveCount(vm) <= vm.gcThreshold) return;
	orcCollectCycles(vm.arrayHeap, vm.objectHeap);
	let next = vmLiveCount(vm) * 2;
	if (next < 256) next = 256;
	vm.gcThreshold = next;
}

function setReg(vm: RaiserVM, idx: number, val: RaiserValue): void {
	if (idx >= vm.regs.slots.length) ensureSlots(vm.regs, idx + 1);
	if (vm.gcMode === "orc") {
		// incref-before-decref: safe under self-assignment (setReg(i, slots[i]))
		const old = vm.regs.slots[idx];
		rcIncref(vm.arrayHeap, vm.objectHeap, val);
		vm.regs.slots[idx] = val;
		rcDecref(vm.arrayHeap, vm.objectHeap, old);
		return;
	}
	vm.regs.slots[idx] = val;
}

// --- Error helper ---

function vmError(vm: RaiserVM, msg: string): void {
	vm.error = msg;
	vm.halted = true;
}

const MAX_CALL_DEPTH = 1024;

// --- Execute ---

export function execModule(mod: RaiserModule, gcMode: string = "arena"): RaiserVM {
	const vm = createVM(mod, gcMode);
	execLoop(vm);
	return vm;
}

export function vmCallFunction(vm: RaiserVM, funcIdx: number, args: RaiserValue[]): RaiserValue {
	if (funcIdx < 0 || funcIdx >= vm.mod.functions.length) {
		vmError(vm, `vmCallFunction: function index out of bounds: ${funcIdx}`);
		return raiserNil();
	}
	const callee = getModuleFunc(vm.mod, funcIdx);
	vm.funcIdx = funcIdx;
	vm.baseReg = 0;
	vm.ip = 0;
	vm.halted = false;
	vm.error = "";
	vm.loopCount = 0;
	vm.callStack.items.length = 0;
	ensureSlots(vm.regs, callee.maxRegs);
	let i = 0;
	while (i < args.length) {
		const slot = raiserNil();
		copyValueInto(slot, args[i]);
		setReg(vm, i, slot);
		i = i + 1;
	}
	execLoop(vm);
	return vm.exitValue;
}

export function execLoop(vm: RaiserVM): void {
	const mod = vm.mod;
	while (!vm.halted) {
		const func = getModuleFunc(mod, vm.funcIdx);
		const inst = getFuncInst(func, vm.ip);
		vm.ip = vm.ip + 1;
		const op = inst.op;
		const base = vm.baseReg;

		// --- Core ops ---
		if (op === RaiserOpcode.LoadConst) {
			const bx = getBx(inst);
			if (bx >= getFuncConstLen(func)) {
				vmError(vm, `constant index out of bounds: ${bx}`);
			} else {
				const val = getFuncConst(func, bx);
				// Copy to avoid aliasing — constant pool objects are shared
				const copy = raiserNil();
				copyValueInto(copy, val);
				setReg(vm, base + inst.a, copy);
			}
		} else if (op === RaiserOpcode.Move) {
			// Copy to avoid aliasing between registers
			const src = getReg(vm, base + inst.b);
			const copy = raiserNil();
			copyValueInto(copy, src);
			setReg(vm, base + inst.a, copy);
		} else if (op === RaiserOpcode.LoadNil) {
			setReg(vm, base + inst.a, raiserNil());
		} else if (op === RaiserOpcode.Halt) {
			vm.halted = true;
			vm.exitValue = getReg(vm, base + inst.a);
		} else if (op === RaiserOpcode.Jump) {
			const offset = getSignedAx(inst);
			if (offset < 0) {
				// Loop back-edge: this is ONE iteration. Straight-line code is
				// finite by construction and recursion is bounded by
				// MAX_CALL_DEPTH, so back-edges are the only unbounded source
				// worth budgeting (reference: handleJmpBack decrements
				// loopIterations only on backward jumps).
				vm.loopCount = vm.loopCount + 1;
				if (vm.loopCount > vm.loopLimit) {
					vmError(vm, `interpretation requires too many iterations (limit ${vm.loopLimit}); if you are sure this is not a bug in your code, raise it with --max-vm-iterations=<n>`);
					break;
				}
			}
			vm.ip = vm.ip + offset;
		// --- i64 arithmetic ---
		} else if (op === RaiserOpcode.AddI64) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			setReg(vm, base + inst.a, raiserInt(lhs.intVal + rhs.intVal));
		} else if (op === RaiserOpcode.SubI64) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			setReg(vm, base + inst.a, raiserInt(lhs.intVal - rhs.intVal));
		} else if (op === RaiserOpcode.MulI64) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			setReg(vm, base + inst.a, raiserInt(lhs.intVal * rhs.intVal));
		} else if (op === RaiserOpcode.DivI64) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			if (rhs.intVal === 0) { vmError(vm, "integer division by zero");
			} else {
				const quot: int32 = (lhs.intVal as int32 / rhs.intVal as int32) | 0;
				setReg(vm, base + inst.a, raiserInt(quot as number));
			}
		} else if (op === RaiserOpcode.ModI64) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			if (rhs.intVal === 0) { vmError(vm, "integer modulo by zero");
			} else {
				setReg(vm, base + inst.a, raiserInt(lhs.intVal % rhs.intVal));
			}
		} else if (op === RaiserOpcode.NegI64) {
			const val = getReg(vm, base + inst.b);
			setReg(vm, base + inst.a, raiserInt(-val.intVal));
		// --- i64 compare-branch ---
		} else if (op === RaiserOpcode.BeqI64) {
			const lhs = getReg(vm, base + inst.a);
			const rhs = getReg(vm, base + inst.b);
			if (lhs.intVal === rhs.intVal) vm.ip = vm.ip + inst.c;
		} else if (op === RaiserOpcode.BneI64) {
			const lhs = getReg(vm, base + inst.a);
			const rhs = getReg(vm, base + inst.b);
			if (lhs.intVal !== rhs.intVal) vm.ip = vm.ip + inst.c;
		} else if (op === RaiserOpcode.BltI64) {
			const lhs = getReg(vm, base + inst.a);
			const rhs = getReg(vm, base + inst.b);
			if (lhs.intVal < rhs.intVal) vm.ip = vm.ip + inst.c;
		} else if (op === RaiserOpcode.BleI64) {
			const lhs = getReg(vm, base + inst.a);
			const rhs = getReg(vm, base + inst.b);
			if (lhs.intVal <= rhs.intVal) vm.ip = vm.ip + inst.c;
		} else if (op === RaiserOpcode.BgtI64) {
			const lhs = getReg(vm, base + inst.a);
			const rhs = getReg(vm, base + inst.b);
			if (lhs.intVal > rhs.intVal) vm.ip = vm.ip + inst.c;
		} else if (op === RaiserOpcode.BgeI64) {
			const lhs = getReg(vm, base + inst.a);
			const rhs = getReg(vm, base + inst.b);
			if (lhs.intVal >= rhs.intVal) vm.ip = vm.ip + inst.c;
		// --- Bitwise ---
		} else if (op === RaiserOpcode.BitAnd) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			const la: int32 = lhs.intVal as int32;
			const ra: int32 = rhs.intVal as int32;
			setReg(vm, base + inst.a, raiserInt((la & ra) as number));
		} else if (op === RaiserOpcode.BitOr) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			const lo: int32 = lhs.intVal as int32;
			const ro: int32 = rhs.intVal as int32;
			setReg(vm, base + inst.a, raiserInt((lo | ro) as number));
		} else if (op === RaiserOpcode.BitXor) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			const lx: int32 = lhs.intVal as int32;
			const rx: int32 = rhs.intVal as int32;
			setReg(vm, base + inst.a, raiserInt((lx ^ rx) as number));
		} else if (op === RaiserOpcode.BitNot) {
			const val = getReg(vm, base + inst.b);
			const vn: int32 = val.intVal as int32;
			setReg(vm, base + inst.a, raiserInt((~vn) as number));
		} else if (op === RaiserOpcode.ShiftLeft) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			const lsl: int32 = lhs.intVal as int32;
			const rsl: int32 = rhs.intVal as int32;
			setReg(vm, base + inst.a, raiserInt((lsl << rsl) as number));
		} else if (op === RaiserOpcode.ShiftRight) {
			const lhs = getReg(vm, base + inst.b);
			const rhs = getReg(vm, base + inst.c);
			const lsr: int32 = lhs.intVal as int32;
			const rsr: int32 = rhs.intVal as int32;
			setReg(vm, base + inst.a, raiserInt((lsr >> rsr) as number));
		// --- Complex ops (previously handled in MetaScript fallback) ---
		} else if (op === RaiserOpcode.Print) {
			const val = getReg(vm, base + inst.a);
			const s = raiserToString(val);
			vm.output = `${vm.output}${s}\n`;
		} else if (op === RaiserOpcode.Call) {
			vmHandleCall(vm, inst);
		} else if (op === RaiserOpcode.CallIndirect) {
			vmHandleCallIndirect(vm, inst);
		} else if (op === RaiserOpcode.Ret) {
			vmHandleRet(vm, inst);
		} else if (op === RaiserOpcode.NewArray) {
			vmHandleNewArray(vm, inst);
		} else if (op === RaiserOpcode.LoadIndex) {
			vmHandleLoadIndex(vm, inst);
		} else if (op === RaiserOpcode.StoreIndex) {
			vmHandleStoreIndex(vm, inst);
		} else if (op === RaiserOpcode.ArrayLen) {
			vmHandleArrayLen(vm, inst);
		} else if (op === RaiserOpcode.ArrayPush) {
			vmHandleArrayPush(vm, inst);
		} else if (op === RaiserOpcode.NewObject) {
			vmHandleNewObject(vm, inst);
		} else if (op === RaiserOpcode.LoadField) {
			vmHandleLoadField(vm, mod, inst);
		} else if (op === RaiserOpcode.StoreField) {
			vmHandleStoreField(vm, mod, inst);
		} else if (op === RaiserOpcode.ConcatStr) {
			vmHandleConcatStr(vm, inst);
		} else if (op === RaiserOpcode.EqStr) {
			vmHandleEqStr(vm, inst);
		} else if (op === RaiserOpcode.NeStr) {
			vmHandleNeStr(vm, inst);
		} else if (op === RaiserOpcode.LtStr) {
			vmHandleLtStr(vm, inst);
		} else if (op === RaiserOpcode.LeStr) {
			vmHandleLeStr(vm, inst);
		} else if (op === RaiserOpcode.StrLen) {
			vmHandleStrLen(vm, inst);
		} else if (op === RaiserOpcode.StrCharAt) {
			vmHandleStrCharAt(vm, inst);
		} else if (op === RaiserOpcode.StrSlice) {
			vmHandleStrSlice(vm, inst);
		} else if (op === RaiserOpcode.AddF64) {
			vmHandleAddF64(vm, inst);
		} else if (op === RaiserOpcode.SubF64) {
			vmHandleSubF64(vm, inst);
		} else if (op === RaiserOpcode.MulF64) {
			vmHandleMulF64(vm, inst);
		} else if (op === RaiserOpcode.DivF64) {
			vmHandleDivF64(vm, inst);
		} else if (op === RaiserOpcode.NegF64) {
			vmHandleNegF64(vm, inst);
		} else if (op === RaiserOpcode.BeqF64) {
			vmCmpBranchF64(vm, inst, 0);
		} else if (op === RaiserOpcode.BneF64) {
			vmCmpBranchF64(vm, inst, 1);
		} else if (op === RaiserOpcode.BltF64) {
			vmCmpBranchF64(vm, inst, 2);
		} else if (op === RaiserOpcode.BleF64) {
			vmCmpBranchF64(vm, inst, 3);
		} else if (op === RaiserOpcode.BgtF64) {
			vmCmpBranchF64(vm, inst, 4);
		} else if (op === RaiserOpcode.BgeF64) {
			vmCmpBranchF64(vm, inst, 5);
		} else if (op === RaiserOpcode.CallHost) {
			vmHandleCallHost(vm, inst);
		} else if (op === RaiserOpcode.IsNil) {
			const v = getReg(vm, base + inst.b);
			setReg(vm, base + inst.a, raiserBool(v.kind === RaiserValueKind.Nil));
		} else {
			vmError(vm, `Unknown opcode: ${op}`);
		}
	}
}

// --- Call/Ret handlers ---

function vmHandleCall(vm: RaiserVM, inst: RaiserInstruction): void {
	if (vm.callStack.items.length >= MAX_CALL_DEPTH) {
		vmError(vm, `call stack overflow (depth ${MAX_CALL_DEPTH})`); return;
	}
	const destReg = inst.a;
	const calleeFuncIdx = inst.b;
	const argCount = inst.c;

	// Validate callee function index
	if (calleeFuncIdx < 0 || calleeFuncIdx >= vm.mod.functions.length) {
		vmError(vm, `function index out of bounds: ${calleeFuncIdx}`); return;
	}

	// Reserve the callee's frame: starting at newBase, up to its maxRegs.
	// Without this pre-allocation, the first opcode in the callee that
	// accesses a register beyond the current slots length would crash with
	// `index N out of bounds (length M)` from the runtime array bounds
	// check — there's no per-opcode guard.
	const newBase = vm.baseReg + destReg + 1;
	const callee = getModuleFunc(vm.mod, calleeFuncIdx);
	ensureSlots(vm.regs, newBase + callee.maxRegs);

	// Push caller's frame (save current function name for stack traces)
	const callerFunc = getModuleFunc(vm.mod, vm.funcIdx);
	const frame: RaiserCallFrame = {
		funcIdx: vm.funcIdx,
		returnIp: vm.ip,
		returnReg: vm.baseReg + destReg,
		baseReg: vm.baseReg,
		funcName: callerFunc.name,
	};
	vm.callStack.items.push(frame);

	// Callee's base = right at args (R[dest+1..dest+N] become callee's R[0..N-1])
	vm.baseReg = newBase;
	vm.funcIdx = calleeFuncIdx;
	vm.ip = 0;
}

function vmHandleRet(vm: RaiserVM, inst: RaiserInstruction): void {
	if (vm.callStack.items.length === 0) {
		// Top-level return — halt
		copyValueInto(vm.exitValue, getReg(vm, vm.baseReg + inst.a));
		vm.halted = true;
		return;
	}

	// Pop frame
	const len = vm.callStack.items.length;
	const frame = vm.callStack.items[len - 1];
	vm.callStack.items.length = len - 1;

	// Copy return value to caller's dest register (fresh object avoids aliasing)
	const retCopy = raiserNil();
	copyValueInto(retCopy, getReg(vm, vm.baseReg + inst.a));
	setReg(vm, frame.returnReg, retCopy);

	// No blanket frame-exit decref: the global register file is reused across
	// calls, so a callee slot may hold a stale handle from a prior frame that this
	// frame never owned — decref-ing the whole range over-decrefs it (UAF).
	// Reclamation instead happens lazily via setReg's decref-on-overwrite when the
	// slot is next written (frame reuse). Residual: a never-reused slot's ref lingers.

	// Restore caller state
	vm.funcIdx = frame.funcIdx;
	vm.baseReg = frame.baseReg;
	vm.ip = frame.returnIp;
}

function vmHandleCallIndirect(vm: RaiserVM, inst: RaiserInstruction): void {
	if (vm.callStack.items.length >= MAX_CALL_DEPTH) {
		vmError(vm, `call stack overflow (depth ${MAX_CALL_DEPTH})`); return;
	}
	const destReg = inst.a;
	const funcIdxReg = getReg(vm, vm.baseReg + inst.b);
	const calleeFuncIdx = funcIdxReg.intVal;
	const argCount = inst.c;

	// Validate callee function index
	if (calleeFuncIdx < 0 || calleeFuncIdx >= vm.mod.functions.length) {
		vmError(vm, `function index out of bounds: ${calleeFuncIdx}`); return;
	}

	// Reserve the callee's frame (same rationale as vmHandleCall).
	const newBase = vm.baseReg + destReg + 1;
	const callee = getModuleFunc(vm.mod, calleeFuncIdx);
	ensureSlots(vm.regs, newBase + callee.maxRegs);

	// Push caller's frame
	const callerFunc = getModuleFunc(vm.mod, vm.funcIdx);
	const frame: RaiserCallFrame = {
		funcIdx: vm.funcIdx,
		returnIp: vm.ip,
		returnReg: vm.baseReg + destReg,
		baseReg: vm.baseReg,
		funcName: callerFunc.name,
	};
	vm.callStack.items.push(frame);

	// Callee's base = right at args (R[dest+1..dest+N] become callee's R[0..N-1])
	vm.baseReg = newBase;
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
		vmIncref(vm, elem);
	}
	const arrVal = raiserArray(handle);
	setReg(vm, vm.baseReg + inst.a, arrVal);
	vmMaybeCollect(vm);
}

function vmHandleLoadIndex(vm: RaiserVM, inst: RaiserInstruction): void {
	const arrVal = getReg(vm, vm.baseReg + inst.b);
	const idxVal = getReg(vm, vm.baseReg + inst.c);
	const handle = arrVal.intVal;
	const idx = idxVal.intVal;
	if (handle < 0 || handle >= vm.arrayHeap.arrays.length) {
		vmError(vm, `array handle out of bounds: ${handle}`); return;
	}
	const arrLen = heapArrayLen(vm.arrayHeap, handle);
	if (idx < 0 || idx >= arrLen) {
		vmError(vm, `array index out of bounds: ${idx} (length ${arrLen})`); return;
	}
	const elem = heapArrayGet(vm.arrayHeap, handle, idx);
	// Deep copy to avoid aliasing
	const dst = getReg(vm, vm.baseReg + inst.a);
	vmIncref(vm, elem);
	vmDecref(vm, dst);
	copyValueInto(dst, elem);
}

function vmHandleStoreIndex(vm: RaiserVM, inst: RaiserInstruction): void {
	const arrVal = getReg(vm, vm.baseReg + inst.a);
	const idxVal = getReg(vm, vm.baseReg + inst.b);
	const val = getReg(vm, vm.baseReg + inst.c);
	const handle = arrVal.intVal;
	const idx = idxVal.intVal;
	if (handle < 0 || handle >= vm.arrayHeap.arrays.length) {
		vmError(vm, `array handle out of bounds: ${handle}`); return;
	}
	const arrLen = heapArrayLen(vm.arrayHeap, handle);
	if (idx < 0 || idx >= arrLen) {
		vmError(vm, `array index out of bounds: ${idx} (length ${arrLen})`); return;
	}
	vmIncref(vm, val);
	vmDecref(vm, heapArrayGet(vm.arrayHeap, handle, idx));
	heapArraySet(vm.arrayHeap, handle, idx, val);
}

function vmHandleArrayLen(vm: RaiserVM, inst: RaiserInstruction): void {
	const arrVal = getReg(vm, vm.baseReg + inst.b);
	const handle = arrVal.intVal;
	if (handle < 0 || handle >= vm.arrayHeap.arrays.length) {
		vmError(vm, `array handle out of bounds: ${handle}`); return;
	}
	const len = heapArrayLen(vm.arrayHeap, handle);
	const result = raiserInt(len);
	setReg(vm, vm.baseReg + inst.a, result);
}

function vmHandleArrayPush(vm: RaiserVM, inst: RaiserInstruction): void {
	const arrVal = getReg(vm, vm.baseReg + inst.a);
	const val = getReg(vm, vm.baseReg + inst.b);
	const handle = arrVal.intVal;
	if (handle < 0 || handle >= vm.arrayHeap.arrays.length) {
		vmError(vm, `array handle out of bounds: ${handle}`); return;
	}
	heapArrayPush(vm.arrayHeap, handle, val);
	vmIncref(vm, val);
}

// --- Object opcode handlers ---

function vmHandleNewObject(vm: RaiserVM, inst: RaiserInstruction): void {
	const handle = heapAllocObject(vm.objectHeap);
	const objVal = raiserObject(handle);
	setReg(vm, vm.baseReg + inst.a, objVal);
	vmMaybeCollect(vm);
}

function vmHandleLoadField(vm: RaiserVM, mod: RaiserModule, inst: RaiserInstruction): void {
	const objVal = getReg(vm, vm.baseReg + inst.b);
	const handle = objVal.intVal;
	if (handle < 0 || handle >= vm.objectHeap.objects.length) {
		vmError(vm, `object handle out of bounds: ${handle}`); return;
	}
	const obj = vm.objectHeap.objects[handle];
	const fields = obj.fields;

	// MIC: try cached index first
	let idx = inst.cachedIdx;
	if (idx >= 0 && idx < fields.length) {
		const func = getModuleFunc(mod, vm.funcIdx);
		const nameVal = getFuncConst(func, inst.c);
		if (fields[idx].name === nameVal.strVal) {
			// Cache hit — O(1) access
			const dstHit = getReg(vm, vm.baseReg + inst.a);
			vmIncref(vm, fields[idx].value);
			vmDecref(vm, dstHit);
			copyValueInto(dstHit, fields[idx].value);
			return;
		}
	}

	// Cache miss — linear scan, then update cache
	const func = getModuleFunc(mod, vm.funcIdx);
	const nameVal = getFuncConst(func, inst.c);
	const fieldName = nameVal.strVal;
	let fi = 0;
	while (fi < fields.length) {
		if (fields[fi].name === fieldName) {
			inst.cachedIdx = fi;
			const dstMiss = getReg(vm, vm.baseReg + inst.a);
			vmIncref(vm, fields[fi].value);
			vmDecref(vm, dstMiss);
			copyValueInto(dstMiss, fields[fi].value);
			return;
		}
		fi = fi + 1;
	}
	// Field not found — load nil
	const dst = getReg(vm, vm.baseReg + inst.a);
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Nil;
	dst.intVal = 0;
	dst.floatVal = 0.0;
	dst.strVal = "";
}

function vmHandleStoreField(vm: RaiserVM, mod: RaiserModule, inst: RaiserInstruction): void {
	const objVal = getReg(vm, vm.baseReg + inst.a);
	const handle = objVal.intVal;
	if (handle < 0 || handle >= vm.objectHeap.objects.length) {
		vmError(vm, `object handle out of bounds: ${handle}`); return;
	}
	const obj = vm.objectHeap.objects[handle];
	const fields = obj.fields;
	const val = getReg(vm, vm.baseReg + inst.c);

	// MIC: try cached index first
	let idx = inst.cachedIdx;
	if (idx >= 0 && idx < fields.length) {
		const func = getModuleFunc(mod, vm.funcIdx);
		const nameVal = getFuncConst(func, inst.b);
		if (fields[idx].name === nameVal.strVal) {
			// Cache hit — O(1) update
			vmIncref(vm, val);
			vmDecref(vm, fields[idx].value);
			copyValueInto(fields[idx].value, val);
			return;
		}
	}

	// Cache miss — linear scan, then update cache
	const func = getModuleFunc(mod, vm.funcIdx);
	const nameVal = getFuncConst(func, inst.b);
	const fieldName = nameVal.strVal;
	let fi = 0;
	while (fi < fields.length) {
		if (fields[fi].name === fieldName) {
			inst.cachedIdx = fi;
			vmIncref(vm, val);
			vmDecref(vm, fields[fi].value);
			copyValueInto(fields[fi].value, val);
			return;
		}
		fi = fi + 1;
	}
	// New field — append
	vmIncref(vm, val);
	const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal, strVal: val.strVal };
	const field: RaiserObjectField = { name: fieldName, value: copy };
	fields.push(field);
	inst.cachedIdx = fields.length - 1;
}

// --- String opcode handlers ---

function vmHandleConcatStr(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.b);
	const rhs = getReg(vm, vm.baseReg + inst.c);
	const result = raiserToString(lhs) + raiserToString(rhs);
	const dst = getReg(vm, vm.baseReg + inst.a);
	vmDecref(vm, dst);
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

function vmHandleLtStr(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (lhs.strVal < rhs.strVal) {
		vm.ip = vm.ip + inst.c;
	}
}

function vmHandleLeStr(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.a);
	const rhs = getReg(vm, vm.baseReg + inst.b);
	if (lhs.strVal <= rhs.strVal) {
		vm.ip = vm.ip + inst.c;
	}
}

// --- String method handlers ---

function vmHandleStrLen(vm: RaiserVM, inst: RaiserInstruction): void {
	const src = getReg(vm, vm.baseReg + inst.b);
	const dst = getReg(vm, vm.baseReg + inst.a);
	vmDecref(vm, dst);
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
	vmDecref(vm, dst);
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
	vmDecref(vm, dst);
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
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) + asNum(rhs);
	dst.intVal = 0;
	dst.strVal = "";
}

function vmHandleSubF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.b);
	const rhs = getReg(vm, vm.baseReg + inst.c);
	const dst = getReg(vm, vm.baseReg + inst.a);
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) - asNum(rhs);
	dst.intVal = 0;
	dst.strVal = "";
}

function vmHandleMulF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.b);
	const rhs = getReg(vm, vm.baseReg + inst.c);
	const dst = getReg(vm, vm.baseReg + inst.a);
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) * asNum(rhs);
	dst.intVal = 0;
	dst.strVal = "";
}

function vmHandleDivF64(vm: RaiserVM, inst: RaiserInstruction): void {
	const lhs = getReg(vm, vm.baseReg + inst.b);
	const rhs = getReg(vm, vm.baseReg + inst.c);
	const dst = getReg(vm, vm.baseReg + inst.a);
	vmDecref(vm, dst);
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
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = 0.0 - asNum(src);
	dst.intVal = 0;
	dst.strVal = "";
}

// --- Float compare-branch handlers ---

function vmCmpBranchF64(vm: RaiserVM, inst: RaiserInstruction, cmpOp: number): void {
	const l = asNum(getReg(vm, vm.baseReg + inst.a));
	const r = asNum(getReg(vm, vm.baseReg + inst.b));
	let cond = false;
	if (cmpOp === 0) { cond = l === r; }
	else if (cmpOp === 1) { cond = l !== r; }
	else if (cmpOp === 2) { cond = l < r; }
	else if (cmpOp === 3) { cond = l <= r; }
	else if (cmpOp === 4) { cond = l > r; }
	else if (cmpOp === 5) { cond = l >= r; }
	if (cond) { vm.ip = vm.ip + inst.c; }
}

// --- Bitwise handlers ---

// Bitwise ops are handled entirely in C dispatch (vmDispatch.c)
// using int64_t casts — MetaScript fallback not needed.

// --- CallHost handler ---
// Generic name-resolved native call. The only host-call mechanism. Lookup
// is O(n) over the registry, but n is small (~20-200 host fns) and the
// registered wrappers (in src/compiler/meta/hostTable.ms) own all
// type-specific marshalling.

function vmHandleCallHost(vm: RaiserVM, inst: RaiserInstruction): void {
	const base = vm.baseReg;
	const func = getModuleFunc(vm.mod, vm.funcIdx);
	const nameConst = getFuncConst(func, inst.b);
	if (nameConst.kind !== RaiserValueKind.String) {
		vmError(vm, `CallHost expected string constant at index ${inst.b}, got kind ${nameConst.kind}`);
		return;
	}
	const name = nameConst.strVal;

	const fn = lookupHostFn(name);
	if (fn === (null as unknown as RaiserHostFn)) {
		vmError(vm, `Unknown host function: ${name}`);
		return;
	}

	// Collect args from R[A+1] .. R[A+C]
	const args: RaiserValue[] = [];
	let i = 0;
	while (i < inst.c) {
		const argVal = getReg(vm, base + inst.a + 1 + i);
		args.push(argVal);
		i = i + 1;
	}

	// Save/restore so a bridge that re-enters a nested VM leaves the outer
	// VM's heaps active when it resumes.
	const prevObjHeap = activeHostObjectHeap();
	const prevArrHeap = activeHostArrayHeap();
	setActiveHostHeaps(vm.objectHeap, vm.arrayHeap);
	const result = fn(args);
	if (prevObjHeap !== null && prevArrHeap !== null) {
		setActiveHostHeaps(prevObjHeap, prevArrHeap);
	}

	const dst = getReg(vm, base + inst.a);
	vmIncref(vm, result);
	vmDecref(vm, dst);
	copyValueInto(dst, result);
}

// --- Stack trace ---

export function vmDumpStack(vm: RaiserVM): string {
	let trace = "Trace:";
	// Walk call stack from bottom (oldest) to top (newest)
	let i = 0;
	while (i < vm.callStack.items.length) {
		const frame = vm.callStack.items[i];
		const func = getModuleFunc(vm.mod, frame.funcIdx);
		const inst = getFuncInst(func, frame.returnIp > 0 ? frame.returnIp - 1 : 0);
		const ln = inst.line;
		if (ln > 0) {
			trace = `${trace}\n  line ${ln} in ${frame.funcName}`;
		} else {
			trace = `${trace}\n  ${frame.funcName}`;
		}
		i = i + 1;
	}
	// Current frame (top of stack)
	const curFunc = getModuleFunc(vm.mod, vm.funcIdx);
	const curIp = vm.ip > 0 ? vm.ip - 1 : 0;
	if (curIp < curFunc.code.length) {
		const curInst = getFuncInst(curFunc, curIp);
		const curLn = curInst.line;
		if (curLn > 0) {
			trace = `${trace}\n  line ${curLn} in ${curFunc.name} (current)`;
		} else {
			trace = `${trace}\n  ${curFunc.name} (current)`;
		}
	} else {
		trace = `${trace}\n  ${curFunc.name} (current)`;
	}
	return trace;
}

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
	assert vm.exitValue.intVal === 42;
}

test "add: 10 + 20 = 30" { assert execBinOp(RaiserOpcode.AddI64, 10, 20).exitValue.intVal === 30; }

test "sub: 100 - 42 = 58" { assert execBinOp(RaiserOpcode.SubI64, 100, 42).exitValue.intVal === 58; }

test "mul: 6 * 7 = 42" { assert execBinOp(RaiserOpcode.MulI64, 6, 7).exitValue.intVal === 42; }

test "div: 84 / 2 = 42" { assert execBinOp(RaiserOpcode.DivI64, 84, 2).exitValue.intVal === 42; }

test "mod: 17 % 5 = 2" { assert execBinOp(RaiserOpcode.ModI64, 17, 5).exitValue.intVal === 2; }

test "neg: -(7) = -7" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.NegI64, 1, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(7)]
	));
	assert vm.exitValue.intVal === -7;
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
	assert vm.exitValue.intVal === 20;
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
	assert vm.output === "42\n";
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
	assert vm.exitValue.intVal === 1;
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
	assert vm.exitValue.intVal === 0;
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
	assert vm.exitValue.intVal === 15;
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
	assert vm.exitValue.intVal === 1;
}

test "NewArray empty" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),   // R0 = []
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[]
	));
	assert vm.exitValue.kind === RaiserValueKind.Array;
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
	assert vm.exitValue.intVal === 20;
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
	assert vm.exitValue.intVal === 3;
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
	assert vm.exitValue.intVal === 1;
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
	assert vm.exitValue.intVal === 99;
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
	assert vm.exitValue.intVal === 42;
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
	assert vm.exitValue.intVal === 20;
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
	assert vm.exitValue.intVal === 99;
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
	assert vm.exitValue.strVal === "hello world";
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
	assert vm.exitValue.strVal === "val: 42";
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
	assert vm.exitValue.intVal === 1;
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
	assert vm.exitValue.intVal === 0;
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
	assert vm.exitValue.intVal === 1;
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
	assert vm.exitValue.intVal === 5;
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
	assert vm.exitValue.strVal === "e";
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
	assert vm.exitValue.strVal === "hello";
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
	assert vm.exitValue.intVal === 0;
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
	assert vm.exitValue.intVal === 42;
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
	assert vm.exitValue.intVal === 30;
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
	assert vm.exitValue.intVal === 42;
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
	assert vm.exitValue.intVal === 5;
}

// --- Phase 5: Safety & Diagnostics tests ---

test "iteration budget counts loop back-edges, not instructions" {
	// Tight backward-jump loop: Jump(-1) re-executes itself forever. The
	// budget counts each backward jump as ONE iteration (reference parity:
	// maxLoopIterationsVM) and stops with a message naming the escape flag.
	const code: RaiserInstruction[] = [
		raiserAx(RaiserOpcode.Jump, -1),  // after fetch ip=1, -1 → stays at 0
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [];
	const func = createRaiserFunction("loop", code, consts, 0, 0, 1);
	const funcs: RaiserFunction[] = [func];
	const mod = createRaiserModule("test", funcs, 0);
	const vm = createVM(mod);
	vm.loopLimit = 100;  // low budget for a fast test
	execLoop(vm);        // custom budget applies — no manual dispatch needed
	assert vm.halted;
	assert vm.error.indexOf("too many iterations") >= 0;
	assert vm.error.indexOf("--max-vm-iterations=") >= 0;
	assert vm.loopCount === 101;
}

test "forward jumps are free; only back-edges consume the budget" {
	// Countdown K=3: the back-edge executes exactly 3 times; the forward
	// Beq exit and all straight-line instructions cost nothing. Pre-fix
	// (per-instruction counting) this program spent 20+ budget units.
	const consts: RaiserValue[] = [raiserInt(3), raiserInt(1), raiserInt(0)];
	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),   // R0 = 3
		raiserABx(RaiserOpcode.LoadConst, 1, 1),   // R1 = 1
		raiserABx(RaiserOpcode.LoadConst, 2, 2),   // R2 = 0
		raiserABC(RaiserOpcode.BeqI64, 0, 2, 3),   // if R0 == 0 skip 3 → ip 7
		raiserABC(RaiserOpcode.SubI64, 0, 0, 1),   // R0 -= 1
		raiserAx(RaiserOpcode.Jump, -3),           // ip 6-3 = 3 — the back-edge
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),     // skipped pad
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),     // exit, R0 = 0
	];
	const func = createRaiserFunction("countdown", code, consts, 0, 0, 3);
	const funcs: RaiserFunction[] = [func];
	const mod = createRaiserModule("test", funcs, 0);
	const vm = execModule(mod);
	assert vm.error === "";
	assert vm.loopCount === 3;
	assert vm.exitValue.intVal === 0;
}

test "unknown opcode sets error" {
	// Use an impossibly high opcode number by manually crafting instruction
	const code: RaiserInstruction[] = [
		{ op: 999 as RaiserOpcode, a: 0, b: 0, c: 0, cachedIdx: -1, line: 0 },
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error !== "";
}

test "stack trace with function calls" {
	// Build: main calls inner, inner halts
	const innerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const innerConsts: RaiserValue[] = [raiserInt(42)];
	const inner = createRaiserFunction("inner", innerCode, innerConsts, 0, 0, 1);

	const mainCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Call, 0, 0, 0), // call inner
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const mainConsts: RaiserValue[] = [];
	const main = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 1);

	const funcs: RaiserFunction[] = [inner, main];
	const mod = createRaiserModule("test", funcs, 1);
	const vm = execModule(mod);
	assert vm.exitValue.intVal === 42;
	// The VM halted inside inner — stack trace should show the call chain
	const trace = vmDumpStack(vm);
	assert trace.length > 0;
}

// --- CallHost tests ---
// Verifies the new generic native-call opcode end-to-end through the registry
// + marshal layer. Uses synthetic host functions (echo, add) rather than
// real std/* natives so this test is independent of Phase 3 wiring.

test "CallHost echo string roundtrip" {
	_resetHostRegistryForTests();
	const echoFn: RaiserHostFn = (args: RaiserValue[]): RaiserValue => {
		return args[0];
	};
	registerHostFn("echo", echoFn);

	// constants[0] = "echo" (name), constants[1] = "hello" (arg)
	// Bytecode: R1 = "hello"; CallHost R0(name=consts[0], argc=1); Halt R0
	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 1, 1),         // R1 = "hello"
		raiserABC(RaiserOpcode.CallHost, 0, 0, 1),       // R0 = echo(R1)
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [raiserString("echo"), raiserString("hello")];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error === "";
	assert vm.exitValue.kind === RaiserValueKind.String;
	assert vm.exitValue.strVal === "hello";
}

test "CallHost two-arg native" {
	_resetHostRegistryForTests();
	const addFn: RaiserHostFn = (args: RaiserValue[]): RaiserValue => {
		return raiserInt(args[0].intVal + args[1].intVal);
	};
	registerHostFn("add", addFn);

	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 1, 1),         // R1 = 10
		raiserABx(RaiserOpcode.LoadConst, 2, 2),         // R2 = 32
		raiserABC(RaiserOpcode.CallHost, 0, 0, 2),       // R0 = add(R1, R2)
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [raiserString("add"), raiserInt(10), raiserInt(32)];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error === "";
	assert vm.exitValue.intVal === 42;
}

test "CallHost zero-arg native" {
	_resetHostRegistryForTests();
	const constFn: RaiserHostFn = (args: RaiserValue[]): RaiserValue => {
		return raiserInt(7);
	};
	registerHostFn("seven", constFn);

	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),       // R0 = seven()
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [raiserString("seven")];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error === "";
	assert vm.exitValue.intVal === 7;
}

test "CallHost unknown name errors" {
	_resetHostRegistryForTests();
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [raiserString("missingFn")];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error.length > 0;
	assert vm.halted;
}

test "instruction line field preserved" {
	const inst = raiserABC(RaiserOpcode.AddI64, 0, 1, 2);
	assert inst.line === 0;
	inst.line = 42;
	assert inst.line === 42;
}

// --- Phase 1 Safety Tests ---

test "div by zero sets error" {
	const vm = execBinOp(RaiserOpcode.DivI64, 10, 0);
	assert vm.error === "integer division by zero";
	assert vm.halted;
}

test "mod by zero sets error" {
	const vm = execBinOp(RaiserOpcode.ModI64, 10, 0);
	assert vm.error === "integer modulo by zero";
	assert vm.halted;
}

test "array index out of bounds" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 1, 0),     // R1 = 10
			raiserABC(RaiserOpcode.NewArray, 0, 1, 0),   // R0 = [10]
			raiserABx(RaiserOpcode.LoadConst, 2, 1),     // R2 = 5 (bad index)
			raiserABC(RaiserOpcode.LoadIndex, 3, 0, 2),  // R3 = R0[5] — OOB
			raiserABC(RaiserOpcode.Halt, 3, 0, 0),
		],
		[raiserInt(10), raiserInt(5)]
	));
	assert vm.error.length > 0;
	assert vm.halted;
}

test "array negative index" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 1, 0),     // R1 = 10
			raiserABC(RaiserOpcode.NewArray, 0, 1, 0),   // R0 = [10]
			raiserABx(RaiserOpcode.LoadConst, 2, 1),     // R2 = -1
			raiserABC(RaiserOpcode.LoadIndex, 3, 0, 2),  // R3 = R0[-1] — OOB
			raiserABC(RaiserOpcode.Halt, 3, 0, 0),
		],
		[raiserInt(10), raiserInt(-1)]
	));
	assert vm.error.length > 0;
	assert vm.halted;
}

test "store to invalid array handle" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),     // R0 = 999 (bad handle)
			raiserABx(RaiserOpcode.LoadConst, 1, 1),     // R1 = 0 (index)
			raiserABx(RaiserOpcode.LoadConst, 2, 1),     // R2 = 0 (value)
			raiserABC(RaiserOpcode.StoreIndex, 0, 1, 2), // R0[0] = 0 — bad handle
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(999), raiserInt(0)]
	));
	assert vm.error.length > 0;
	assert vm.halted;
}

test "object handle out of bounds" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),     // R0 = -1 (bad handle)
			raiserABC(RaiserOpcode.LoadField, 1, 0, 1),  // R1 = R0.field — bad handle
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(-1), raiserString("x")]
	));
	assert vm.error.length > 0;
	assert vm.halted;
}

test "constant index out of bounds" {
	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 9999),  // K9999 doesn't exist
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [raiserInt(1)];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error.length > 0;
	assert vm.halted;
}

test "call depth overflow" {
	// func0 calls itself recursively: Call R0 0 0 (call func[0] with 0 args)
	const func0Code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Call, 0, 0, 0),  // recurse forever
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const func0Consts: RaiserValue[] = [];
	const f0 = createRaiserFunction("recurse", func0Code, func0Consts, 0, 0, 2);
	const funcs: RaiserFunction[] = [f0];
	const mod = createRaiserModule("test", funcs, 0);
	const vm = execModule(mod);
	assert vm.error.length > 0;
	assert vm.halted;
}

test "vmCallFunction: trampoline call with scalar args" {
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
		raiserABC(RaiserOpcode.Ret, 2, 0, 0),
	];
	const consts: RaiserValue[] = [];
	const addFn = createRaiserFunction("add", code, consts, 2, 0, 4);
	const funcs: RaiserFunction[] = [addFn];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = createVM(mod, "arena");
	const a1 = raiserInt(3);
	const a2 = raiserInt(4);
	const args: RaiserValue[] = [a1, a2];
	const r = vmCallFunction(vm, 0, args);
	assert r.intVal === 7;
}

test "vmCallFunction: reusable VM, different args, no recompile" {
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
		raiserABC(RaiserOpcode.Ret, 2, 0, 0),
	];
	const consts: RaiserValue[] = [];
	const addFn = createRaiserFunction("add", code, consts, 2, 0, 4);
	const funcs: RaiserFunction[] = [addFn];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = createVM(mod, "arena");
	const x1 = raiserInt(10);
	const x2 = raiserInt(20);
	const argsA: RaiserValue[] = [x1, x2];
	const rA = vmCallFunction(vm, 0, argsA);
	assert rA.intVal === 30;
	const y1 = raiserInt(1);
	const y2 = raiserInt(2);
	const argsB: RaiserValue[] = [y1, y2];
	const rB = vmCallFunction(vm, 0, argsB);
	assert rB.intVal === 3;
}

test "vmCallFunction: nested Call/Ret through trampoline" {
	// func0 addOne(a): R2 = R0 + K0(1); Ret R2
	const f0Code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
		raiserABC(RaiserOpcode.Ret, 2, 0, 0),
	];
	const f0Consts: RaiserValue[] = [raiserInt(1)];
	const f0 = createRaiserFunction("addOne", f0Code, f0Consts, 1, 0, 4);
	// func1 addTwo(a): R1 = addOne(a); R1 = addOne(R1); Ret R1
	const f1Code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Move, 2, 0, 0),
		raiserABC(RaiserOpcode.Call, 1, 0, 1),
		raiserABC(RaiserOpcode.Move, 2, 1, 0),
		raiserABC(RaiserOpcode.Call, 1, 0, 1),
		raiserABC(RaiserOpcode.Ret, 1, 0, 0),
	];
	const f1Consts: RaiserValue[] = [];
	const f1 = createRaiserFunction("addTwo", f1Code, f1Consts, 1, 0, 8);
	const funcs: RaiserFunction[] = [f0, f1];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = createVM(mod, "arena");
	const a = raiserInt(5);
	const args: RaiserValue[] = [a];
	const r = vmCallFunction(vm, 1, args);
	assert r.intVal === 7;
}
