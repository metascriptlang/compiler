// Raiser VM — Bytecode executor

import {
	RaiserOpcode, RaiserInstruction, RaiserConvClass, convClassBits, convClassSigned, convTarget, convSource, convOperand,
	raiserABC, raiserABx, raiserAx,
	packedOp, packedA, packedBx, packedBranch, immValue, immField, branchField
} from "./bytecode";
import {
	RaiserValue, RaiserValueKind,
	raiserNil, raiserInt, raiserFloat, raiserConstString, raiserArray, raiserToString, copyValueInto,
	RaiserArrayHeap, createArrayHeap, heapAllocArray, heapAllocView, heapArrayIsView, heapArrayGet, heapArraySet, heapArrayPush, heapArraySetLen, heapArrayLen,
	RaiserObjectHeap, RaiserObjectField, createStructHeap, heapAllocObject, raiserObject, heapObjectGetField, raiserIsInstance, RAISER_NO_CLASS,
	raiserFuture, raiserElemAddr, raiserFieldAddrAt, fieldAddrName, heapObjectSetField, heapAllocString, heapStringText, heapStringLive,
	rcIncref, rcDecref, rcIncrefHandle, rcDecrefHandle, copyGraph, copyGraphWith, createCopyMap, RaiserCopyMap, raiserToBool, constStringText, constStringCount, clearArrayHeap, clearObjectHeap,
} from "./value";
import {
	RaiserModule, RaiserFunction,
	makeTestModule, assertPacked, getFuncConst, getFuncConstLen, getModuleFunc, createRaiserFunction, createRaiserModule,
} from "./module";
import { orcCollectCycles } from "./orc";
import { RaiserCopyKind, copyTypedValue } from "./valueCopy";
import { parseIntStr } from "../utils/string";
import { HostCapability, lookupHostFn, hostFnAllowedInRestrictedMode, registerHostFn, _resetHostRegistryForTests, setActiveHostHeaps, activeHostObjectHeap, activeHostArrayHeap, setActiveProgramArgv, activeProgramArgv, takeHostRaise, hostRaiseIsFatal, raiseFromHost } from "./hostRegistry";
import { RaiserHostFn, RaiserPrintSink, boxString } from "./marshal";
import { int64Bits } from "../utils/stdBackport";

@include("runtime/promise/dispatch.h");
extern function msMonoTimeMs(): int64;
extern function msSleepMs(ms: int32): void;
extern function msFloat64Bits(d: float64): uint64;
extern function msToInt32(d: float64): int32;

// --- VM State ---

export interface RaiserRegFile {
	slots: RaiserValue[];
}

export interface RaiserCallFrame {
	funcIdx: int32;
	returnIp: int32;
	returnReg: int32;
	baseReg: int32;
	spBase: int32;   // safePoints length where the callee's own handlers begin
}

// items[0..depth) are the live frames; a popped record stays for the next call to rewrite.
export interface RaiserCallFrames {
	items: RaiserCallFrame[];
	depth: number;
}

// A strand is one independent line of execution: its own register file, its
// own frame stack and its own heap. The whole of it is reified data — MS-level
// calls never use the host stack (vmHandleCall pushes a frame and re-points
// funcIdx/ip/baseReg) — so a strand suspends by copying those fields out of
// the VM and resumes by copying them back. No CPS transform, no per-opcode
// changes: vm.arrayHeap / vm.objectHeap are the running strand's heap, so
// every allocating opcode stays exactly as it was.
export enum RaiserStrandStatus {
	Ready,
	Running,
	Blocked,
	Done,
}

export interface RaiserStrand {
	id: number;
	globals: RaiserValue[];
	regs: RaiserRegFile;
	callStack: RaiserCallFrames;
	arrayHeap: RaiserArrayHeap;
	objectHeap: RaiserObjectHeap;
	ip: int32;
	funcIdx: int32;
	baseReg: int32;
	loopCount: number;
	status: RaiserStrandStatus;
	result: RaiserValue;
	resultFuture: int64;   // future this strand completes when it finishes; -1 for main
	safePoints: number[];
	currentException: RaiserValue;
}

export interface RaiserStrands {
	items: RaiserStrand[];
}

// The VM's msFuture (runtime/promise/future.h): a completion cell plus the
// readers parked on it. One OS thread means none of the cross-thread fields
// (atomics, crossThreadPublished, deferred release) have a counterpart here;
// `waiters` is what msFutureCb is for on C — the list woken on completion.
export interface RaiserFuture {
	finished: boolean;
	failed: boolean;
	errorMsg: string;
	errorObserved: boolean;
	value: RaiserValue;
	error: RaiserValue;
	// The future owns the storage its value lives in, the way MS_FUTURE_STRUCT
	// makes `value` a field of the future itself (runtime/promise/future.h) —
	// the producing strand's heap dies with it, so the value is copied in on
	// completion and copied out into each reader's heap on await.
	valueArrayHeap: RaiserArrayHeap;
	valueObjectHeap: RaiserObjectHeap;
	waiters: number[];   // strand indices blocked on this future
	record: int32;       // module record an import() future settles from; -1 for any other future
}

export interface RaiserFutures {
	items: RaiserFuture[];
}

export interface RaiserTimer {
	dueMs: int64;
	future: int64;
}

export interface RaiserTimers {
	items: RaiserTimer[];
}

// The module records of the modules import() reaches, evaluated on a task strand that
// shares the main strand's globals and heap, the way runtime/promise/moduleEval.c
// evaluates them on the loop thread. A body with a top-level await runs on a strand of
// its own that shares them too, so its await parks only that strand.
export enum RaiserModuleStatus {
	Pending,
	Evaluating,
	EvaluatingAsync,
	Evaluated,
}

export interface RaiserModuleState {
	status: RaiserModuleStatus;
	failed: boolean;
	error: RaiserValue;
	dfsIndex: int32;
	dfsAncestorIndex: int32;
	asyncEvaluation: boolean;
	asyncOrdinal: int32;
	pendingAsyncDeps: int32;
	asyncParents: int32[];
	cycleRoot: int32;
	waiters: int64[];      // import() futures settled when the evaluation finishes
	bodyStrand: number;    // strand running the body with a top-level await; -1 otherwise
}

export enum RaiserModuleJobKind {
	Import,
	Fulfilled,
	Rejected,
}

export interface RaiserModuleJob {
	kind: RaiserModuleJobKind;
	record: int32;
	future: int64;         // the import() future of an Import job; -1 otherwise
	error: RaiserValue;    // what the body of a Rejected job threw
}

export interface RaiserModuleFrame {
	at: int32;
	next: int32;   // next requested module to visit; requested.length = body due, beyond = body ran
}

export interface RaiserModuleEval {
	states: RaiserModuleState[];
	pending: RaiserModuleJob[];
	strand: number;    // strand running the evaluator task; -1 when no task is armed
	fresh: boolean;    // the task resumes in the evaluator rather than in bytecode
	stack: int32[];
	frames: RaiserModuleFrame[];
	index: int32;
	nextOrdinal: int32;
	starting: number;  // body strand that runs before the task resumes; -1 when none
	execList: int32[];
	execAt: int32;
	execBody: int32;   // record of the execList body the task is running; -1 otherwise
}

export interface RaiserSched {
	strands: RaiserStrands;
	futures: RaiserFutures;
	timers: RaiserTimers;
	nextStrandId: number;
	modules: RaiserModuleEval;
}

export interface RaiserVM {
	mod: RaiserModule;
	globals: RaiserValue[];
	regs: RaiserRegFile;
	ip: int32;
	halted: boolean;
	exitValue: RaiserValue;
	output: string;
	printSink: RaiserPrintSink | null;
	funcIdx: int32;
	baseReg: int32;
	callStack: RaiserCallFrames;
	arrayHeap: RaiserArrayHeap;
	objectHeap: RaiserObjectHeap;
	loopCount: number;   // backward jumps (loop iterations) since the last entry reset
	loopLimit: number;   // max loop iterations before the VM refuses (reference: maxLoopIterationsVM)
	error: string;    // Non-empty when VM stopped due to error
	gcMode: string;   // "arena" (default, no RC) | "orc" (refcount + cycle collector)
	orc: boolean;     // gcMode == "orc", decided once in createVM
	gcThreshold: number;  // live-object count that triggers a cycle collection (orc)
	sched: RaiserSched;
	current: number;      // index into sched.strands.items of the running strand
	yielded: boolean;     // set by Yield / strand completion, consumed by the scheduler
	// Exception state of the running strand. safePoints holds the pending try
	// handlers of the CURRENT function only — a call stashes them on the frame.
	safePoints: number[];
	currentException: RaiserValue;
	diagMessage: string;
	diagLine: number;
	diagColumn: number;
	diagEndLine: number;
	diagEndColumn: number;
	hostCallsRestricted: boolean;
	hostPolicySource: string;
	programArgv: string[] | null;   // what the program's `argv` reads; null leaves the host's own argv visible
	frameFloor: number;
	suspendedRuns: RaiserRun[];
}

interface RaiserRun {
	floor: number;
	funcIdx: int32;
	baseReg: int32;
	ip: int32;
	halted: boolean;
	yielded: boolean;
	exitValue: RaiserValue;
	error: string;
	diagMessage: string;
	diagLine: number;
	diagColumn: number;
	diagEndLine: number;
	diagEndColumn: number;
	loopCount: number;
	globals: RaiserValue[];
	regs: RaiserRegFile;
	callStack: RaiserCallFrames;
	arrayHeap: RaiserArrayHeap;
	objectHeap: RaiserObjectHeap;
	sched: RaiserSched;
	current: number;
	safePoints: number[];
	currentException: RaiserValue;
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
	if (gcMode != "arena" && gcMode != "orc") throw new Error(`internal: unknown Raiser gcMode "${gcMode}"`);
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
	const callStack: RaiserCallFrames = { items: callFrames, depth: 0 };
	const arrayHeap = createArrayHeap();
	const objectHeap = createStructHeap();
	const mainResult = raiserNil();
	const mainSafePoints: number[] = [];
	const globals: RaiserValue[] = [];
	for (let i = 0; i < mod.globalCount; i += 1) globals.push(raiserNil());
	const mainStrand: RaiserStrand = { id: 0, globals, regs, callStack, arrayHeap, objectHeap, ip: 0, funcIdx: mod.entry as int32, baseReg: 0, loopCount: 0, status: RaiserStrandStatus.Running, result: mainResult, resultFuture: -1, safePoints: mainSafePoints, currentException: raiserNil() };
	const strandItems: RaiserStrand[] = [mainStrand];
	const strands: RaiserStrands = { items: strandItems };
	const futureItems: RaiserFuture[] = [];
	const futures: RaiserFutures = { items: futureItems };
	const timerItems: RaiserTimer[] = [];
	const timers: RaiserTimers = { items: timerItems };
	const sched: RaiserSched = { strands, futures, timers, nextStrandId: 1, modules: createModuleEval(mod) };
	const safePoints: number[] = [];
	return { mod, globals, regs, ip: 0, halted: false, exitValue: nilVal, output: "", printSink: null, funcIdx: mod.entry as int32, baseReg: 0, callStack, arrayHeap, objectHeap, loopCount: 0, loopLimit: vmLoopLimitDefault, error: "", gcMode, orc: gcMode == "orc", gcThreshold: 256, sched, current: 0, yielded: false, safePoints, currentException: raiserNil(), diagMessage: "", diagLine: 0, diagColumn: 0, diagEndLine: 0, diagEndColumn: 0, hostCallsRestricted: false, hostPolicySource: "", programArgv: null, frameFloor: 0, suspendedRuns: [] };
}

// --- Register access via helper functions (DRC-safe) ---

// Slot accessors. Every Call/CallIndirect/spawn reserves baseReg + callee.maxRegs
// slots before control transfers, so an access past the file is a codegen bug
// (maxRegs underestimating its function), reported by name.
function slotOutside(idx: number): Error {
	return new Error(`internal: register ${idx} is outside the reserved register file`);
}

function getReg(vm: RaiserVM, idx: number): RaiserValue {
	if (idx >= vm.regs.slots.length) throw slotOutside(idx);
	return vm.regs.slots[idx];
}

// --- Refcount helpers: ORC counts every heap kind; arena mode counts strings only,
// because arrays and objects live until the heap is dropped but a string freed by
// its last holder keeps a long-running loop's memory bounded ---

function vmHold(vm: RaiserVM, kind: RaiserValueKind, handle: int64): void {
	if (vm.orc || kind == RaiserValueKind.String) rcIncrefHandle(vm.arrayHeap, vm.objectHeap, kind, handle);
}

function vmRelease(vm: RaiserVM, kind: RaiserValueKind, handle: int64): void {
	if (vm.orc || kind == RaiserValueKind.String) rcDecrefHandle(vm.arrayHeap, vm.objectHeap, kind, handle);
}

function vmIncref(vm: RaiserVM, val: RaiserValue): void {
	vmHold(vm, val.kind, val.intVal);
}

function vmDecref(vm: RaiserVM, val: RaiserValue): void {
	vmRelease(vm, val.kind, val.intVal);
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
	if (!vm.orc) return;
	if (vmLiveCount(vm) <= vm.gcThreshold) return;
	orcCollectCycles(vm.arrayHeap, vm.objectHeap);
	let next = vmLiveCount(vm) * 2;
	if (next < 256) next = 256;
	vm.gcThreshold = next;
}

// A register slot owns one box for its lifetime (ensureSlots makes it); every
// write goes into that box and no other location ever holds it, so a value
// leaves a register only by being copied out.
function setReg(vm: RaiserVM, idx: number, val: RaiserValue): void {
	if (idx >= vm.regs.slots.length) throw slotOutside(idx);
	// Kinds below String hold no heap handle, so a scalar move skips both counters.
	// incref-before-decref: safe under self-assignment (setReg(i, slots[i]))
	if (val.kind >= RaiserValueKind.String) vmHold(vm, val.kind, val.intVal);
	const oldKind = vm.regs.slots[idx].kind;
	const oldHandle = vm.regs.slots[idx].intVal;
	copyValueInto(vm.regs.slots[idx], val);
	if (oldKind >= RaiserValueKind.String) vmRelease(vm, oldKind, oldHandle);
}

function setRegScalar(vm: RaiserVM, idx: number, kind: RaiserValueKind, intVal: int64, floatVal: number): void {
	const dst = getReg(vm, idx);
	const oldKind = dst.kind;
	const oldHandle = dst.intVal;
	dst.kind = kind;
	dst.intVal = intVal;
	dst.floatVal = floatVal;
	if (oldKind >= RaiserValueKind.String) vmRelease(vm, oldKind, oldHandle);
}

function setRegInt(vm: RaiserVM, idx: number, n: int64): void {
	setRegScalar(vm, idx, RaiserValueKind.Int, n, 0.0);
}

function setRegFloat(vm: RaiserVM, idx: number, f: number): void {
	setRegScalar(vm, idx, RaiserValueKind.Float, 0, f);
}

function setRegBool(vm: RaiserVM, idx: number, b: boolean): void {
	setRegScalar(vm, idx, RaiserValueKind.Bool, b ? 1 : 0, 0.0);
}

function setRegNil(vm: RaiserVM, idx: number): void {
	setRegScalar(vm, idx, RaiserValueKind.Nil, 0, 0.0);
}

function setRegString(vm: RaiserVM, idx: number, s: string): void {
	setRegRef(vm, idx, RaiserValueKind.String, heapAllocString(vm.arrayHeap, s).intVal);
}

function vmText(vm: RaiserVM, v: RaiserValue): string {
	return heapStringText(vm.arrayHeap, v);
}

function setRegRef(vm: RaiserVM, idx: number, kind: RaiserValueKind, handle: int64): void {
	const dst = getReg(vm, idx);
	vmHold(vm, kind, handle);
	const oldKind = dst.kind;
	const oldHandle = dst.intVal;
	dst.kind = kind;
	dst.intVal = handle;
	dst.floatVal = 0.0;
	vmRelease(vm, oldKind, oldHandle);
}

// --- Error helper ---

function vmError(vm: RaiserVM, msg: string): void {
	vm.error = msg;
	vm.halted = true;
}

const MAX_CALL_DEPTH = 1024;
const INT64_LOW: int64 = -9223372036854775807 - 1;

function mulOverflowsI64(a: int64, b: int64): boolean {
	if (a == 0 || b == 0) return false;
	if (a == -1) return b == INT64_LOW;
	if (b == -1) return a == INT64_LOW;
	return int64Bits((a as uint64) * (b as uint64)) / a != b;
}
const MAX_ARRAY_COUNT = 4294967295;

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
	if (vm.frameFloor > 0 && !runSuspendedAt(vm, vm.frameFloor)) suspendRun(vm);
	vm.funcIdx = funcIdx as int32;
	vm.baseReg = vm.frameFloor as int32;
	vm.ip = 0;
	vm.halted = false;
	vm.error = "";
	vm.exitValue = raiserNil();
	vm.diagMessage = "";
	vm.loopCount = 0;
	vm.callStack.depth = 0;
	resetStrands(vm, funcIdx);
	ensureSlots(vm.regs, vm.baseReg + callee.maxRegs);
	let i = 0;
	while (i < args.length) {
		setReg(vm, vm.baseReg + i, args[i]);
		i = i + 1;
	}
	execLoop(vm);
	return vm.exitValue;
}

export function vmReleaseHeaps(vm: RaiserVM): void {
	if (vm.frameFloor > 0) return;
	clearObjectHeap(vm.objectHeap);
	clearArrayHeap(vm.arrayHeap);
}

function runSuspendedAt(vm: RaiserVM, floor: number): boolean {
	const runs = vm.suspendedRuns;
	return runs.length > 0 && runs[runs.length - 1].floor == floor;
}

function suspendRun(vm: RaiserVM): void {
	vm.suspendedRuns.push({
		floor: vm.frameFloor, funcIdx: vm.funcIdx, baseReg: vm.baseReg, ip: vm.ip, halted: vm.halted, yielded: vm.yielded,
		exitValue: vm.exitValue, error: vm.error, diagMessage: vm.diagMessage, diagLine: vm.diagLine, diagColumn: vm.diagColumn,
		diagEndLine: vm.diagEndLine, diagEndColumn: vm.diagEndColumn, loopCount: vm.loopCount, globals: vm.globals, regs: vm.regs,
		callStack: vm.callStack, arrayHeap: vm.arrayHeap, objectHeap: vm.objectHeap, sched: vm.sched, current: vm.current,
		safePoints: vm.safePoints, currentException: vm.currentException,
	});
	const frames: RaiserCallFrame[] = [];
	vm.callStack = { items: frames, depth: 0 };
	const strandItems: RaiserStrand[] = [];
	const futureItems: RaiserFuture[] = [];
	const timerItems: RaiserTimer[] = [];
	vm.sched = { strands: { items: strandItems }, futures: { items: futureItems }, timers: { items: timerItems }, nextStrandId: 1, modules: createModuleEval(vm.mod) };
	vm.safePoints = [];
	vm.currentException = raiserNil();
}

function resumeRun(vm: RaiserVM, run: RaiserRun): void {
	vm.funcIdx = run.funcIdx;
	vm.baseReg = run.baseReg;
	vm.ip = run.ip;
	vm.halted = run.halted;
	vm.yielded = run.yielded;
	vm.exitValue = run.exitValue;
	vm.error = run.error;
	vm.diagMessage = run.diagMessage;
	vm.diagLine = run.diagLine;
	vm.diagColumn = run.diagColumn;
	vm.diagEndLine = run.diagEndLine;
	vm.diagEndColumn = run.diagEndColumn;
	vm.loopCount = run.loopCount;
	vm.globals = run.globals;
	vm.regs = run.regs;
	vm.callStack = run.callStack;
	vm.arrayHeap = run.arrayHeap;
	vm.objectHeap = run.objectHeap;
	vm.sched = run.sched;
	vm.current = run.current;
	vm.safePoints = run.safePoints;
	vm.currentException = run.currentException;
}

// --- Strand scheduling ---

function resetStrands(vm: RaiserVM, entryFuncIdx: number): void {
	vm.sched.strands.items.length = 0;
	const result = raiserNil();
	vm.safePoints.length = 0;
	// The main strand keeps the VM's existing heap objects: the host holds that
	// identity across runs (context.ms captures it, vmReleaseHeaps clears it).
	const mainStrand: RaiserStrand = { id: 0, globals: vm.globals, regs: vm.regs, callStack: vm.callStack, arrayHeap: vm.arrayHeap, objectHeap: vm.objectHeap, ip: 0, funcIdx: entryFuncIdx as int32, baseReg: 0, loopCount: 0, status: RaiserStrandStatus.Running, result, resultFuture: -1, safePoints: vm.safePoints, currentException: vm.currentException };
	vm.sched.strands.items.push(mainStrand);
	vm.current = 0;
	vm.sched.nextStrandId = 1;
	vm.yielded = false;
	vm.sched.futures.items.length = 0;
	vm.sched.timers.items.length = 0;
	const ev = vm.sched.modules;
	ev.pending.length = 0;
	ev.strand = -1;
	ev.fresh = false;
	ev.stack.length = 0;
	ev.frames.length = 0;
	ev.starting = -1;
	ev.execList.length = 0;
	ev.execAt = 0;
	ev.execBody = -1;
	for (const st of ev.states) st.bodyStrand = -1;
}

// --- Futures ---

function newFuture(vm: RaiserVM): int64 {
	const waiters: number[] = [];
	const valueArrayHeap = createArrayHeap();
	const valueObjectHeap = createStructHeap();
	const f: RaiserFuture = { finished: false, failed: false, errorMsg: "", errorObserved: false, value: raiserNil(), error: raiserNil(), valueArrayHeap, valueObjectHeap, waiters, record: -1 };
	vm.sched.futures.items.push(f);
	return vm.sched.futures.items.length - 1;
}

function futureComplete(vm: RaiserVM, handle: int64, value: RaiserValue): void {
	if (handle < 0 || handle >= vm.sched.futures.items.length) {
		vmError(vm, `future handle out of bounds: ${handle}`);
		return;
	}
	const f = vm.sched.futures.items[handle];
	if (f.finished) return;
	f.finished = true;
	// Completion runs on the producing strand, whose heap dies with it — the
	// value graph moves into storage the future owns.
	const owned = copyGraphWith(vm.arrayHeap, vm.objectHeap, f.valueArrayHeap, f.valueObjectHeap, value, strandCopyMap(vm));
	rcIncref(f.valueArrayHeap, f.valueObjectHeap, owned);
	copyValueInto(f.value, owned);
	for (const w of f.waiters) {
		const s = vm.sched.strands.items[w];
		if (s.status == RaiserStrandStatus.Blocked) s.status = RaiserStrandStatus.Ready;
	}
	f.waiters.length = 0;
}

// --- Timers ---

function vmArmTimer(vm: RaiserVM, delay: RaiserValue): int64 {
	let ms: int64 = 0;
	if (delay.kind == RaiserValueKind.Float && delay.floatVal > 0) ms = delay.floatVal as int64;
	if (delay.kind == RaiserValueKind.Int && delay.intVal > 0) ms = delay.intVal;
	const timer: RaiserTimer = { dueMs: msMonoTimeMs() + ms, future: newFuture(vm) };
	const items = vm.sched.timers.items;
	items.push(timer);
	let at = items.length - 1;
	while (at > 0 && items[at - 1].dueMs > timer.dueMs) {
		items[at] = items[at - 1];
		at -= 1;
	}
	items[at] = timer;
	return timer.future;
}

function vmFireDueTimer(vm: RaiserVM): void {
	const items = vm.sched.timers.items;
	if (items.length == 0 || items[0].dueMs > msMonoTimeMs()) return;
	const timer = items[0];
	for (let i = 1; i < items.length; i += 1) items[i - 1] = items[i];
	items.shrink(items.length - 1);
	futureComplete(vm, timer.future, raiserNil());
}

function vmWaitForTimer(vm: RaiserVM): void {
	const wait = vm.sched.timers.items[0].dueMs - msMonoTimeMs();
	if (wait <= 0) return;
	const capped: int64 = wait > 2147483647 ? 2147483647 : wait;
	msSleepMs(capped as int32);
}

function vmHandleSleep(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (!vm.orc) {
		vmError(vm, "sleepAsync is not available in compile-time evaluation: a timer would make its result depend on wall-clock time");
		return;
	}
	const fut = vmArmTimer(vm, getReg(vm, vm.baseReg + ib));
	setRegRef(vm, vm.baseReg + ia, RaiserValueKind.Future, fut);
}

function futureFail(vm: RaiserVM, handle: int64, message: string, thrown: RaiserValue): void {
	if (handle < 0 || handle >= vm.sched.futures.items.length) {
		vmError(vm, `future handle out of bounds: ${handle}`);
		return;
	}
	const f = vm.sched.futures.items[handle];
	if (f.finished) return;
	f.finished = true;
	f.failed = true;
	f.errorMsg = message;
	const owned = copyGraphWith(vm.arrayHeap, vm.objectHeap, f.valueArrayHeap, f.valueObjectHeap, thrown, strandCopyMap(vm));
	rcIncref(f.valueArrayHeap, f.valueObjectHeap, owned);
	copyValueInto(f.error, owned);
	for (const w of f.waiters) {
		const s = vm.sched.strands.items[w];
		if (s.status == RaiserStrandStatus.Blocked) s.status = RaiserStrandStatus.Ready;
	}
	f.waiters.length = 0;
}

// A future that failed and was never read is an unhandled rejection, the same
// contract msReportOrphanFailures enforces at exit on C.
export function vmOrphanFailures(vm: RaiserVM): string[] {
	const out: string[] = [];
	for (const f of vm.sched.futures.items) {
		if (f.failed && !f.errorObserved) out.push(f.errorMsg);
	}
	return out;
}

// --- Exceptions ---
// A per-frame stack of safepoints, each holding the ip of the handler metadata
// its `Try` registered, plus one in-flight exception.

function safePointBase(vm: RaiserVM): number {
	const depth = vm.callStack.depth;
	return depth == 0 ? 0 : vm.callStack.items[depth - 1].spBase;
}

function popSafePoint(vm: RaiserVM): number {
	const n = vm.safePoints.length;
	if (n == safePointBase(vm)) return -1;
	const top = vm.safePoints[n - 1];
	vm.safePoints.length = n - 1;
	return top;
}

// Pop one call frame without delivering a return value: the call is being
// abandoned by an exception.
function unwindFrame(vm: RaiserVM): void {
	const depth = vm.callStack.depth - 1;
	const frame = vm.callStack.items[depth];
	vm.callStack.depth = depth;
	vm.safePoints.length = frame.spBase;
	vm.funcIdx = frame.funcIdx;
	vm.ip = frame.returnIp;
	vm.baseReg = frame.baseReg;
}

function unhandledException(vm: RaiserVM): void {
	const body = moduleBodyOf(vm, vm.current);
	if (body >= 0) {
		moduleBodyFinish(vm, body, RaiserModuleJobKind.Rejected, vm.currentException);
		return;
	}
	const ev = vm.sched.modules;
	if (vm.current == ev.strand) {
		if (ev.execBody >= 0) {
			const at = ev.execBody;
			ev.execBody = -1;
			moduleAsyncRejected(vm, at, vm.currentException);
		} else {
			moduleFail(vm, vm.currentException);
		}
		moduleTaskContinue(vm);
		return;
	}
	const msg = vmExceptionText(vm, vm.currentException);
	const s = vm.sched.strands.items[vm.current];
	if (s.resultFuture >= 0) {
		// A spawned strand dies into its future: a reader re-raises it, and a
		// failure nobody reads is reported as an orphan at exit.
		futureFail(vm, s.resultFuture, msg, vm.currentException);
		s.status = RaiserStrandStatus.Done;
		vm.yielded = true;
		return;
	}
	vmError(vm, `unhandled exception: ${msg}`);
}

const FINALLY_NORMAL: int64 = 0;
const FINALLY_RAISE: int64 = 1;
const FINALLY_RETURN: int64 = 2;

function enterFinally(vm: RaiserVM, routeReg: number, kind: int64, value: RaiserValue): void {
	setRegInt(vm, vm.baseReg + routeReg, kind);
	setReg(vm, vm.baseReg + routeReg + 1, value);
}

// Landing on a Catch ends the unwind; landing on a Finally runs it and comes
// back through FinallyEnd. Out of frames means nobody handled it.
function unwindStep(vm: RaiserVM): void {
	while (true) {
		while (vm.safePoints.length > safePointBase(vm)) {
			const sp = popSafePoint(vm);
			const func = getModuleFunc(vm.mod, vm.funcIdx);
			if (sp < 0 || sp >= func.packed.length) {
				vmError(vm, `safepoint out of bounds: ${sp}`);
				return;
			}
			const meta = func.packed[sp];
			if (packedOp(meta) == RaiserOpcode.Catch) {
				// Bind the caught value into the register the handler names,
				// now rather than later: a throw inside the handler body
				// overwrites currentException.
				setReg(vm, vm.baseReg + packedA(meta), vm.currentException);
				vm.ip = (sp + 1) as int32;
				return;
			}
			if (packedOp(meta) == RaiserOpcode.Finally) {
				enterFinally(vm, packedA(meta), FINALLY_RAISE, vm.currentException);
				vm.ip = (sp + 1) as int32;
				return;
			}
			vmError(vm, `safepoint ${sp} does not point at a handler`);
			return;
		}
		if (vm.callStack.depth == 0) {
			unhandledException(vm);
			return;
		}
		unwindFrame(vm);
	}
}

// Leaving a guarded region by returning still runs its `finally` first.
// Every Try emits a Finally marker, so the innermost safepoint is the only one
// that can own the next finally to run; re-executing the Ret finds the next.
function cleanUpOnReturn(vm: RaiserVM): number {
	const n = vm.safePoints.length;
	if (n == safePointBase(vm)) return -1;
	const func = getModuleFunc(vm.mod, vm.funcIdx);
	let sp = vm.safePoints[n - 1];
	if (sp < 0 || sp >= func.packed.length) return -1;
	const meta = func.packed[sp];
	if (packedOp(meta) == RaiserOpcode.Catch) sp = sp + packedBx(meta);
	if (sp < 0 || sp >= func.packed.length) return -1;
	const fin = func.packed[sp];
	if (packedOp(fin) != RaiserOpcode.Finally) return -1;
	vm.safePoints.length = n - 1;
	enterFinally(vm, packedA(fin), FINALLY_RETURN, raiserInt((vm.ip - 1) as int64));
	return sp + 1;
}

const MACRO_ERROR_PREFIX = "__MACRO_ERROR__:";

function vmExceptionText(vm: RaiserVM, thrown: RaiserValue): string {
	if (thrown.kind != RaiserValueKind.Object) return raiserToString(vm.arrayHeap, thrown);
	if (thrown.intVal < 0 || thrown.intVal >= vm.objectHeap.objects.length) {
		vmError(vm, `object handle out of bounds: ${thrown.intVal}`);
		return "";
	}
	return raiserToString(vm.arrayHeap, heapObjectGetField(vm.objectHeap, thrown.intVal, "message"));
}

function vmTakeMacroError(vm: RaiserVM, thrown: RaiserValue): boolean {
	const text = vmExceptionText(vm, thrown);
	if (!text.startsWith(MACRO_ERROR_PREFIX)) return false;
	const payload = text.slice(MACRO_ERROR_PREFIX.length, text.length);
	const parts = payload.split("\t");
	vm.diagMessage = parts.length > 0 ? parts[0] : "compile error in macro";
	vm.diagLine = parts.length > 1 ? parseIntStr(parts[1]) : 0;
	vm.diagColumn = parts.length > 2 ? parseIntStr(parts[2]) : 0;
	vm.diagEndLine = parts.length > 3 ? parseIntStr(parts[3]) : 0;
	vm.diagEndColumn = parts.length > 4 ? parseIntStr(parts[4]) : 0;
	vm.halted = true;
	return true;
}

function vmHandleThrow(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vmTakeMacroError(vm, getReg(vm, vm.baseReg + ia))) return;
	copyValueInto(vm.currentException, getReg(vm, vm.baseReg + ia));
	unwindStep(vm);
}

// Re-raise a failed future in its reader — the VM's msFutureRaiseFrom.
function raiseFromFuture(vm: RaiserVM, f: RaiserFuture): void {
	f.errorObserved = true;
	if (f.record >= 0) copyValueInto(vm.currentException, moduleErrorForReader(vm, f.record));
	else copyValueInto(vm.currentException, f.error.kind == RaiserValueKind.Nil ? heapAllocString(vm.arrayHeap, f.errorMsg) : copyGraph(f.valueArrayHeap, f.valueObjectHeap, vm.arrayHeap, vm.objectHeap, f.error));
	unwindStep(vm);
}

function strandSave(vm: RaiserVM): void {
	const s = vm.sched.strands.items[vm.current];
	s.globals = vm.globals;
	s.regs = vm.regs;
	s.callStack = vm.callStack;
	s.arrayHeap = vm.arrayHeap;
	s.objectHeap = vm.objectHeap;
	s.ip = vm.ip;
	s.funcIdx = vm.funcIdx;
	s.baseReg = vm.baseReg;
	s.loopCount = vm.loopCount;
	s.safePoints = vm.safePoints;
	s.currentException = vm.currentException;
}

function strandResume(vm: RaiserVM, idx: number): void {
	const s = vm.sched.strands.items[idx];
	vm.globals = s.globals;
	vm.current = idx;
	vm.regs = s.regs;
	vm.callStack = s.callStack;
	vm.arrayHeap = s.arrayHeap;
	vm.objectHeap = s.objectHeap;
	vm.ip = s.ip;
	vm.funcIdx = s.funcIdx;
	vm.baseReg = s.baseReg;
	vm.loopCount = s.loopCount;
	vm.safePoints = s.safePoints;
	vm.currentException = s.currentException;
	s.status = RaiserStrandStatus.Running;
}

// Round-robin from the strand after the current one, so a yielding strand
// hands the turn on rather than immediately reclaiming it.
function schedulePick(vm: RaiserVM): number {
	const n = vm.sched.strands.items.length;
	let k = 1;
	while (k <= n) {
		const idx = (vm.current + k) % n;
		if (vm.sched.strands.items[idx].status == RaiserStrandStatus.Ready) return idx;
		k = k + 1;
	}
	return -1;
}

// Returns true when the finished strand was a spawned one and the scheduler
// should pick another; false when the main strand finished, which ends the
// program with its value.
function strandFinish(vm: RaiserVM, value: RaiserValue): boolean {
	const s = vm.sched.strands.items[vm.current];
	copyValueInto(s.result, value);
	s.status = RaiserStrandStatus.Done;
	if (s.resultFuture >= 0) futureComplete(vm, s.resultFuture, value);
	return vm.current != 0;
}

function vmHasRunnable(vm: RaiserVM): boolean {
	for (const s of vm.sched.strands.items) {
		if (s.status == RaiserStrandStatus.Ready) return true;
	}
	return false;
}

function vmHasBlocked(vm: RaiserVM): boolean {
	for (const s of vm.sched.strands.items) {
		if (s.status == RaiserStrandStatus.Blocked) return true;
	}
	return false;
}

// The main strand finishing does not stop the program: pending strands run to
// completion first, the way msDrainUntilIdle (runtime/promise/drain.c) pumps
// the loop after the entry module returns. `abrupt` is process.exit — it
// skips the drain, Node parity.
function finishProgram(vm: RaiserVM, value: RaiserValue, abrupt: boolean): void {
	copyValueInto(vm.exitValue, value);
	if (!abrupt && (vmHasRunnable(vm) || vm.sched.timers.items.length > 0)) {
		vm.yielded = true;
		return;
	}
	vm.halted = true;
}

function strandCopyMap(vm: RaiserVM): RaiserCopyMap {
	const map = createCopyMap();
	map.sourceRegs = vm.regs.slots;
	map.sourceGlobals = vm.globals;
	return map;
}

function copyStrandGlobals(
	vm: RaiserVM,
	arrays: RaiserArrayHeap,
	objects: RaiserObjectHeap,
	map: RaiserCopyMap,
): RaiserValue[] {
	const globals: RaiserValue[] = [];
	map.destGlobals = globals;
	for (const value of vm.globals) {
		const copied = copyGraphWith(vm.arrayHeap, vm.objectHeap, arrays, objects, value, map);
		if (vm.orc || copied.kind == RaiserValueKind.String) rcIncref(arrays, objects, copied);
		const slot = raiserNil();
		copyValueInto(slot, copied);
		globals.push(slot);
	}
	return globals;
}

export function vmSpawnStrand(vm: RaiserVM, funcIdx: number): number {
	if (funcIdx < 0 || funcIdx >= vm.mod.functions.length) {
		vmError(vm, `vmSpawnStrand: function index out of bounds: ${funcIdx}`);
		return -1;
	}
	const callee = getModuleFunc(vm.mod, funcIdx as number);
	const slots: RaiserValue[] = [];
	const regs: RaiserRegFile = { slots };
	ensureSlots(regs, callee.maxRegs);
	const frames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: frames, depth: 0 };
	const id = vm.sched.nextStrandId;
	vm.sched.nextStrandId = id + 1;
	const result = raiserNil();
	const sp: number[] = [];
	const arrayHeap = createArrayHeap();
	const objectHeap = createStructHeap();
	const globals = copyStrandGlobals(vm, arrayHeap, objectHeap, strandCopyMap(vm));
	const s: RaiserStrand = { id, globals, regs, callStack, arrayHeap, objectHeap, ip: 0, funcIdx: funcIdx as int32, baseReg: 0, loopCount: 0, status: RaiserStrandStatus.Ready, result, resultFuture: -1, safePoints: sp, currentException: raiserNil() };
	vm.sched.strands.items.push(s);
	return id;
}

// Start a strand for a closure pair { fn, env } and hand back the future it
// completes — the VM's msSpawn. env carries the -1 sentinel when the closure
// captures nothing; otherwise it is the callee's last argument, and `spawn`
// takes a zero-arg closure, so env is its only one.
function vmSpawnClosure(vm: RaiserVM, closure: RaiserValue): int64 {
	if (closure.kind != RaiserValueKind.Object) {
		vmError(vm, "spawn expects a closure");
		return -1;
	}
	const fnField = heapObjectGetField(vm.objectHeap, closure.intVal, "fn");
	const funcIdx = fnField.intVal;
	if (fnField.kind != RaiserValueKind.Int || funcIdx < 0 || funcIdx >= vm.mod.functions.length) {
		vmError(vm, `spawn: function index out of bounds: ${funcIdx}`);
		return -1;
	}
	const callee = getModuleFunc(vm.mod, funcIdx as number);
	const slots: RaiserValue[] = [];
	const regs: RaiserRegFile = { slots };
	ensureSlots(regs, callee.maxRegs);
	const arrayHeap = createArrayHeap();
	const objectHeap = createStructHeap();
	const envField = heapObjectGetField(vm.objectHeap, closure.intVal, "env");
	const copyMap = strandCopyMap(vm);
	const globals = copyStrandGlobals(vm, arrayHeap, objectHeap, copyMap);
	if (envField.kind == RaiserValueKind.Object) {
		// C hands the thunk a borrow of the parent's captures and the analyzer
		// proves the parent outlives them; a handle means nothing in another
		// heap, so the capture graph crosses as a copy the child owns.
		const envSlot = copyGraphWith(vm.arrayHeap, vm.objectHeap, arrayHeap, objectHeap, envField, copyMap);
		rcIncref(arrayHeap, objectHeap, envSlot);
		copyValueInto(regs.slots[0], envSlot);
	}
	const frames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: frames, depth: 0 };
	const id = vm.sched.nextStrandId;
	vm.sched.nextStrandId = id + 1;
	const fut = newFuture(vm);
	const result = raiserNil();
	const sp: number[] = [];
	const s: RaiserStrand = { id, globals, regs, callStack, arrayHeap, objectHeap, ip: 0, funcIdx: funcIdx as int32, baseReg: 0, loopCount: 0, status: RaiserStrandStatus.Ready, result, resultFuture: fut, safePoints: sp, currentException: raiserNil() };
	vm.sched.strands.items.push(s);
	return fut;
}

// Reading a future: finished → its value, pending → park the strand on it.
// Parking rewinds to this instruction, so the resumed strand re-reads the now
// finished future and no partial-instruction state has to be saved. PARALOCK
// §6.2 needs three await lowerings on C because its async frames are
// stackless; a strand carries its whole frame stack, so one mechanism covers
// all three — and `await` works at any call depth here.
function vmHandleAwait(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const base = vm.baseReg;
	const v = getReg(vm, base + ib);
	if (v.kind != RaiserValueKind.Future) {
		// Awaiting a plain value is the identity — Promise.resolve semantics.
		setReg(vm, base + ia, v);
		return;
	}
	if (v.intVal < 0 || v.intVal >= vm.sched.futures.items.length) {
		vmError(vm, `future handle out of bounds: ${v.intVal}`);
		return;
	}
	const f = vm.sched.futures.items[v.intVal];
	if (f.finished) {
		if (f.failed) {
			raiseFromFuture(vm, f);
			return;
		}
		// Read out of the future's own storage and into the reader's heap.
		// Non-destructive: the affine rules (R1/R2) make a second await a
		// compile error, so there is no read-once slot to clear here.
		const copy = copyGraph(f.valueArrayHeap, f.valueObjectHeap, vm.arrayHeap, vm.objectHeap, f.value);
		setReg(vm, base + ia, copy);
		return;
	}
	vm.ip = vm.ip - 1;
	const cur = vm.sched.strands.items[vm.current];
	cur.status = RaiserStrandStatus.Blocked;
	f.waiters.push(vm.current);
	vm.yielded = true;
}

// --- Module records ---

function createModuleEval(mod: RaiserModule): RaiserModuleEval {
	const states: RaiserModuleState[] = [];
	for (let i = 0; i < mod.records.length; i += 1) {
		const eager = mod.records[i].init < 0;
		const status = eager ? RaiserModuleStatus.Evaluated : RaiserModuleStatus.Pending;
		const asyncParents: int32[] = [];
		const waiters: int64[] = [];
		states.push({
			status,
			failed: false,
			error: raiserNil(),
			dfsIndex: 0,
			dfsAncestorIndex: 0,
			asyncEvaluation: false,
			asyncOrdinal: 0,
			pendingAsyncDeps: 0,
			asyncParents,
			cycleRoot: i,
			waiters,
			bodyStrand: -1,
		});
	}
	const pending: RaiserModuleJob[] = [];
	const stack: int32[] = [];
	const frames: RaiserModuleFrame[] = [];
	const execList: int32[] = [];
	return {
		states,
		pending,
		strand: -1,
		fresh: false,
		stack,
		frames,
		index: 0,
		nextOrdinal: 0,
		starting: -1,
		execList,
		execAt: 0,
		execBody: -1,
	};
}

function moduleRecordNamed(mod: RaiserModule, name: string): int32 {
	for (let i = 0; i < mod.records.length; i += 1) {
		if (mod.records[i].name == name) return i;
	}
	return -1;
}

function vmHandleModuleImport(vm: RaiserVM, ia: int32, bx: int32, func: RaiserFunction): void {
	const name = bx < getFuncConstLen(func) ? constStringText(getFuncConst(func, bx)) : "";
	const at = moduleRecordNamed(vm.mod, name);
	if (at < 0) {
		vmError(vm, `import() of module '${name}', which has no module record`);
		return;
	}
	const fut = newFuture(vm);
	vm.sched.futures.items[fut].record = at;
	vm.sched.modules.pending.push({ kind: RaiserModuleJobKind.Import, record: at, future: fut, error: raiserNil() });
	if (vm.sched.modules.strand < 0) moduleArmTask(vm);
	setReg(vm, vm.baseReg + ia, raiserFuture(fut));
}

function moduleNewStrand(vm: RaiserVM, funcIdx: number): number {
	const main = vm.sched.strands.items[0];
	const slots: RaiserValue[] = [];
	const regs: RaiserRegFile = { slots };
	const frames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: frames, depth: 0 };
	const sp: number[] = [];
	const id = vm.sched.nextStrandId;
	vm.sched.nextStrandId = id + 1;
	const s: RaiserStrand = { id, globals: main.globals, regs, callStack, arrayHeap: main.arrayHeap, objectHeap: main.objectHeap, ip: 0, funcIdx: funcIdx as int32, baseReg: 0, loopCount: 0, status: RaiserStrandStatus.Ready, result: raiserNil(), resultFuture: -1, safePoints: sp, currentException: raiserNil() };
	vm.sched.strands.items.push(s);
	return vm.sched.strands.items.length - 1;
}

function moduleArmTask(vm: RaiserVM): void {
	vm.sched.modules.strand = moduleNewStrand(vm, vm.mod.entry);
	vm.sched.modules.fresh = true;
}

function moduleTaskContinue(vm: RaiserVM): void {
	if (moduleAdvanceToBody(vm)) return;
	vm.sched.strands.items[vm.current].status = RaiserStrandStatus.Done;
	vm.sched.modules.strand = -1;
	vm.yielded = true;
}

function moduleEnter(ev: RaiserModuleEval, at: int32): void {
	const st = ev.states[at];
	st.status = RaiserModuleStatus.Evaluating;
	st.dfsIndex = ev.index;
	st.dfsAncestorIndex = ev.index;
	st.pendingAsyncDeps = 0;
	ev.index += 1;
	ev.stack.push(at);
	ev.frames.push({ at, next: 0 });
}

function moduleLowerAncestor(m: RaiserModuleState, r: RaiserModuleState): void {
	if (r.dfsAncestorIndex < m.dfsAncestorIndex) m.dfsAncestorIndex = r.dfsAncestorIndex;
}

function moduleFail(vm: RaiserVM, error: RaiserValue): void {
	const ev = vm.sched.modules;
	for (const at of ev.stack) {
		const st = ev.states[at];
		st.status = RaiserModuleStatus.Evaluated;
		st.failed = true;
		copyValueInto(st.error, error);
		vmIncref(vm, error);
	}
	ev.stack.length = 0;
	ev.frames.length = 0;
}

function moduleRunBody(vm: RaiserVM, funcIdx: number): void {
	const body = getModuleFunc(vm.mod, funcIdx);
	ensureSlots(vm.regs, body.maxRegs);
	vm.callStack.depth = 0;
	const sp: number[] = [];
	vm.safePoints = sp;
	vm.funcIdx = funcIdx as int32;
	vm.baseReg = 0;
	vm.ip = 0;
}

// The body runs on its own strand before the task resumes, up to its first await.
function moduleExecuteAsync(vm: RaiserVM, at: int32): void {
	const ev = vm.sched.modules;
	if (vm.current != ev.strand) {
		vmError(vm, `internal: the body of module '${vm.mod.records[at].name}' started outside the module evaluator task`);
		return;
	}
	const init = vm.mod.records[at].init;
	const s = moduleNewStrand(vm, init);
	ensureSlots(vm.sched.strands.items[s].regs, getModuleFunc(vm.mod, init).maxRegs);
	ev.states[at].bodyStrand = s;
	ev.starting = s;
	ev.fresh = true;
	vm.sched.strands.items[vm.current].status = RaiserStrandStatus.Blocked;
	vm.yielded = true;
}

function moduleBodyOf(vm: RaiserVM, strand: number): int32 {
	const states = vm.sched.modules.states;
	for (let i = 0; i < states.length; i += 1) {
		if (states[i].bodyStrand == strand) return i;
	}
	return -1;
}

function moduleBodyFinish(vm: RaiserVM, at: int32, kind: RaiserModuleJobKind, error: RaiserValue): void {
	const ev = vm.sched.modules;
	ev.states[at].bodyStrand = -1;
	vm.sched.strands.items[vm.current].status = RaiserStrandStatus.Done;
	vm.yielded = true;
	const held = raiserNil();
	copyValueInto(held, error);
	vmIncref(vm, held);
	ev.pending.push({ kind, record: at, future: -1, error: held });
	if (ev.strand < 0) moduleArmTask(vm);
}

// While a body runs up to its first await, it is the only strand that runs.
function moduleHandoffPick(vm: RaiserVM): number {
	const ev = vm.sched.modules;
	if (ev.starting < 0) return -1;
	if (vm.sched.strands.items[ev.starting].status == RaiserStrandStatus.Ready) return ev.starting;
	ev.starting = -1;
	vm.sched.strands.items[ev.strand].status = RaiserStrandStatus.Ready;
	return ev.strand;
}

function moduleSettle(vm: RaiserVM, future: int64, at: int32): void {
	const st = vm.sched.modules.states[at];
	vm.sched.futures.items[future].record = at;
	if (st.failed) futureFail(vm, future, vmExceptionText(vm, st.error), raiserNil());
	else futureComplete(vm, future, raiserInt(1));
}

function moduleSettleWaiters(vm: RaiserVM, at: int32): void {
	const st = vm.sched.modules.states[at];
	for (const future of st.waiters) moduleSettle(vm, future, at);
	st.waiters.length = 0;
}

function moduleImportSettle(vm: RaiserVM, future: int64, at: int32): void {
	const st = vm.sched.modules.states[at];
	if (st.status == RaiserModuleStatus.EvaluatingAsync) {
		st.waiters.push(future);
		return;
	}
	if (st.status == RaiserModuleStatus.Evaluated) {
		moduleSettle(vm, future, at);
		return;
	}
	vmError(vm, `internal: import() of module '${vm.mod.records[at].name}' settled while its evaluation is unfinished`);
}

function moduleListHas(list: int32[], at: int32): boolean {
	for (const x of list) {
		if (x == at) return true;
	}
	return false;
}

function moduleGatherAncestors(vm: RaiserVM, at: int32): void {
	const ev = vm.sched.modules;
	for (const p of ev.states[at].asyncParents) {
		const ps = ev.states[p];
		if (ev.states[ps.cycleRoot].failed || moduleListHas(ev.execList, p)) continue;
		ps.pendingAsyncDeps -= 1;
		if (ps.pendingAsyncDeps == 0) {
			ev.execList.push(p);
			if (!vm.mod.records[p].hasTLA) moduleGatherAncestors(vm, p);
		}
	}
}

function moduleAsyncFulfilled(vm: RaiserVM, at: int32): void {
	const ev = vm.sched.modules;
	const st = ev.states[at];
	if (st.failed) return;
	st.asyncEvaluation = false;
	st.status = RaiserModuleStatus.Evaluated;
	moduleSettleWaiters(vm, at);
	ev.execList.length = 0;
	ev.execAt = 0;
	moduleGatherAncestors(vm, at);
	const list = ev.execList;
	for (let i = 1; i < list.length; i += 1) {
		const p = list[i];
		let j = i;
		while (j > 0 && ev.states[list[j - 1]].asyncOrdinal > ev.states[p].asyncOrdinal) {
			list[j] = list[j - 1];
			j -= 1;
		}
		list[j] = p;
	}
}

function moduleAsyncRejected(vm: RaiserVM, at: int32, error: RaiserValue): void {
	const st = vm.sched.modules.states[at];
	if (st.failed) return;
	st.failed = true;
	copyValueInto(st.error, error);
	vmIncref(vm, error);
	st.status = RaiserModuleStatus.Evaluated;
	st.asyncEvaluation = false;
	for (const p of st.asyncParents) moduleAsyncRejected(vm, p, error);
	moduleSettleWaiters(vm, at);
}

function moduleExecBodyFulfilled(vm: RaiserVM, at: int32): void {
	const st = vm.sched.modules.states[at];
	st.asyncEvaluation = false;
	st.status = RaiserModuleStatus.Evaluated;
	moduleSettleWaiters(vm, at);
}

function moduleVisitRequested(vm: RaiserVM, top: RaiserModuleFrame, req: int32): void {
	const ev = vm.sched.modules;
	const m = ev.states[top.at];
	const r = ev.states[req];
	if (r.status == RaiserModuleStatus.Pending) {
		moduleEnter(ev, req);
		return;
	}
	if (r.status != RaiserModuleStatus.Evaluating && r.failed) {
		moduleFail(vm, r.error);
		return;
	}
	top.next += 1;
	let dep = req;
	if (r.status == RaiserModuleStatus.Evaluating) moduleLowerAncestor(m, r);
	else dep = r.cycleRoot;
	const d = ev.states[dep];
	if (d.failed) {
		moduleFail(vm, d.error);
		return;
	}
	if (d.asyncEvaluation) {
		m.pendingAsyncDeps += 1;
		d.asyncParents.push(top.at);
	}
}

// True when the task is busy: a body runs on it, or a body strand starts before it resumes.
function moduleStepFrame(vm: RaiserVM): boolean {
	const ev = vm.sched.modules;
	const top = ev.frames[ev.frames.length - 1];
	const record = vm.mod.records[top.at];
	const st = ev.states[top.at];
	if (top.next < record.requested.length) {
		moduleVisitRequested(vm, top, record.requested[top.next]);
		return false;
	}
	if (top.next == record.requested.length) {
		top.next += 1;
		if (record.init < 0) {
			vmError(vm, `internal: module '${record.name}', initialized at startup, entered evaluation`);
			return false;
		}
		if (st.pendingAsyncDeps > 0 || record.hasTLA) {
			st.asyncEvaluation = true;
			st.asyncOrdinal = ev.nextOrdinal;
			ev.nextOrdinal += 1;
			if (st.pendingAsyncDeps > 0) return false;
			moduleExecuteAsync(vm, top.at);
			return true;
		}
		moduleRunBody(vm, record.init);
		return true;
	}
	ev.frames.pop();
	if (st.dfsAncestorIndex == st.dfsIndex) {
		let popped: int32 = -1;
		while (popped != top.at) {
			popped = ev.stack.pop();
			const ps = ev.states[popped];
			ps.cycleRoot = top.at;
			ps.status = ps.asyncEvaluation ? RaiserModuleStatus.EvaluatingAsync : RaiserModuleStatus.Evaluated;
		}
	}
	return false;
}

function moduleAdvanceToBody(vm: RaiserVM): boolean {
	const ev = vm.sched.modules;
	while (!vm.halted) {
		if (ev.frames.length > 0) {
			if (moduleStepFrame(vm)) return true;
			continue;
		}
		if (ev.execAt < ev.execList.length) {
			const p = ev.execList[ev.execAt];
			ev.execAt += 1;
			if (ev.states[p].failed) continue;
			if (vm.mod.records[p].hasTLA) {
				moduleExecuteAsync(vm, p);
				return true;
			}
			ev.execBody = p;
			moduleRunBody(vm, vm.mod.records[p].init);
			return true;
		}
		ev.execList.length = 0;
		ev.execAt = 0;
		if (ev.pending.length == 0) return false;
		const job = ev.pending[0];
		let at = job.record;
		if (job.kind == RaiserModuleJobKind.Import) {
			const st = ev.states[at];
			if (st.status == RaiserModuleStatus.EvaluatingAsync || st.status == RaiserModuleStatus.Evaluated) {
				at = st.cycleRoot;
			}
			if (ev.states[at].status == RaiserModuleStatus.Pending) {
				ev.index = 0;
				moduleEnter(ev, at);
				continue;
			}
		}
		for (let i = 1; i < ev.pending.length; i += 1) ev.pending[i - 1] = ev.pending[i];
		ev.pending.shrink(ev.pending.length - 1);
		match (job.kind) {
			RaiserModuleJobKind.Import => moduleImportSettle(vm, job.future, at),
			RaiserModuleJobKind.Fulfilled => moduleAsyncFulfilled(vm, at),
			RaiserModuleJobKind.Rejected => {
				moduleAsyncRejected(vm, at, job.error);
				vmDecref(vm, job.error);
			},
		}
	}
	return false;
}

// The error object lives in the main strand's heap, where the body threw it: a reader
// there gets that same object, a spawned strand a copy in its own heap.
function moduleErrorForReader(vm: RaiserVM, at: int32): RaiserValue {
	const error = vm.sched.modules.states[at].error;
	if (vm.current == 0 || vm.current == vm.sched.modules.strand || moduleBodyOf(vm, vm.current) >= 0) return error;
	const main = vm.sched.strands.items[0];
	return copyGraph(main.arrayHeap, main.objectHeap, vm.arrayHeap, vm.objectHeap, error);
}

export function execLoop(vm: RaiserVM): void {
	execStrandLoop(vm);
	// The host reads its result off the mirror once this returns (context.ms,
	// expand.ms, the rgen tests), so whichever strand ran last, the mirror
	// leaves pointing at the main strand's heap. exitValue needs no copy: a
	// finishProgram call either comes from the main strand or is an abrupt Halt,
	// whose operand is an integer exit code.
	if (vm.sched.strands.items.length > 0) {
		const main = vm.sched.strands.items[0];
		vm.arrayHeap = main.arrayHeap;
		vm.objectHeap = main.objectHeap;
		vm.globals = main.globals;
	}
}

function execStrandLoop(vm: RaiserVM): void {
	while (true) {
		runStrandSlice(vm);
		if (vm.halted) return;
		if (!vm.yielded) return;
		vm.yielded = false;
		const cur = vm.sched.strands.items[vm.current];
		if (cur.status == RaiserStrandStatus.Running) cur.status = RaiserStrandStatus.Ready;
		strandSave(vm);
		vmFireDueTimer(vm);
		let next = moduleHandoffPick(vm);
		if (next < 0) next = schedulePick(vm);
		while (next < 0 && vm.sched.timers.items.length > 0 && !vm.halted) {
			vmWaitForTimer(vm);
			vmFireDueTimer(vm);
			next = schedulePick(vm);
		}
		if (vm.halted) return;
		if (next < 0) {
			// Nothing runnable — the event loop is empty and the program is
			// over. A strand still parked on a future nobody can complete is
			// a real deadlock, not an idle loop.
			if (vmHasBlocked(vm)) {
				vmError(vm, "deadlock: no runnable strand");
				return;
			}
			vm.halted = true;
			return;
		}
		strandResume(vm, next);
		if (next == vm.sched.modules.strand && vm.sched.modules.fresh) {
			vm.sched.modules.fresh = false;
			moduleTaskContinue(vm);
		}
	}
}

function vmBackEdgeOverBudget(vm: RaiserVM): boolean {
	vm.loopCount = vm.loopCount + 1;
	return vm.loopCount > vm.loopLimit;
}

function vmLoopLimitMessage(vm: RaiserVM): string {
	return `interpretation requires too many iterations (limit ${vm.loopLimit}); if you are sure this is not a bug in your code, raise it with --max-vm-iterations=<n>`;
}

function runStrandSlice(vm: RaiserVM): void {
	if (vm.halted || vm.yielded) return;
	const mod = vm.mod;
	let funcIdx = vm.funcIdx;
	let func = getModuleFunc(mod, funcIdx);
	assertPacked(func);
	let code = func.packed;
	let regs = vm.regs;
	let slots = regs.slots;
	let ip = vm.ip;
	let base = vm.baseReg;
	while (true) {
		const pc = ip;
		const word = code[pc];
		ip = pc + 1;
		const op = (word & 255) as RaiserOpcode;
		const ia = ((word >> 8) & 65535) as int32;
		const ib = ((word >> 24) & 65535) as int32;
		const ic = ((word >> 40) & 65535) as int32;

		match (op) {
			RaiserOpcode.LoadConst => {
				const bx = (ib * 256 + ic);
				if (bx >= getFuncConstLen(func)) {
					vm.ip = ip; vmError(vm, `constant index out of bounds: ${bx}`); break;
				} else {
					const val = getFuncConst(func, bx);
					setReg(vm, base + ia, val);
				}
			},
			RaiserOpcode.Move => {
				setReg(vm, base + ia, slots[base + ib]);
			},
			RaiserOpcode.LoadGlobal => {
				setReg(vm, base + ia, vm.globals[ib]);
			},
			RaiserOpcode.StoreGlobal => {
				const source = slots[base + ia];
				vmIncref(vm, source);
				vmDecref(vm, vm.globals[ib]);
				copyValueInto(vm.globals[ib], source);
			},
			RaiserOpcode.CopyValue => {
				const source = slots[base + ib];
				const copied = copyTypedValue(vm.arrayHeap, vm.objectHeap, source,
					func.copyPlans, ic as int32);
				setReg(vm, base + ia, copied);
				vmMaybeCollect(vm);
			},
			RaiserOpcode.LoadNil => {
				setRegNil(vm, base + ia);
			},
			RaiserOpcode.Jump => {
				const rawAx = ia * 65536 + ib * 256 + ic;
				const offset = rawAx >= 8388608 ? rawAx - 16777216 : rawAx;
				if (offset < 0) {
					// Loop back-edge: this is ONE iteration. Straight-line code is
					// finite by construction and recursion is bounded by
					// MAX_CALL_DEPTH, so back-edges are the only unbounded source
					// worth budgeting (reference: handleJmpBack decrements
					// loopIterations only on backward jumps).
					if (vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
				}
				ip = ip + (offset as int32);
			},
			RaiserOpcode.BrEqI64 => {
				if (slots[base + ia].intVal == slots[base + ib].intVal) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrNeI64 => {
				if (slots[base + ia].intVal != slots[base + ib].intVal) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrLtI64 => {
				if (slots[base + ia].intVal < slots[base + ib].intVal) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrLeI64 => {
				if (slots[base + ia].intVal <= slots[base + ib].intVal) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrGtI64 => {
				if (slots[base + ia].intVal > slots[base + ib].intVal) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrGeI64 => {
				if (slots[base + ia].intVal >= slots[base + ib].intVal) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrEqI64Imm => {
				if (slots[base + ia].intVal == immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrNeI64Imm => {
				if (slots[base + ia].intVal != immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrLtI64Imm => {
				if (slots[base + ia].intVal < immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrLeI64Imm => {
				if (slots[base + ia].intVal <= immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrGtI64Imm => {
				if (slots[base + ia].intVal > immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.BrGeI64Imm => {
				if (slots[base + ia].intVal >= immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && vmBackEdgeOverBudget(vm)) { vm.ip = ip; vmError(vm, vmLoopLimitMessage(vm)); break; }
					ip = ip + offset;
				}
			},
			RaiserOpcode.LoadInt => {
				setRegInt(vm, base + ia, immValue(ib));
			},
			RaiserOpcode.AddI64Imm => {
				const lhs = slots[base + ib].intVal;
				const imm = immValue(ic);
				const sum = int64Bits((lhs as uint64) + (imm as uint64));
				if ((sum ^ lhs) >= 0 || (sum ^ imm) >= 0) { setRegInt(vm, base + ia, sum);
				} else { vm.ip = ip; vmError(vm, "over- or underflow"); break; }
			},
			RaiserOpcode.SubI64Imm => {
				const lhs = slots[base + ib].intVal;
				const imm = immValue(ic);
				const diff = int64Bits((lhs as uint64) - (imm as uint64));
				if ((diff ^ lhs) >= 0 || (diff ^ ~imm) >= 0) { setRegInt(vm, base + ia, diff);
				} else { vm.ip = ip; vmError(vm, "over- or underflow"); break; }
			},
			RaiserOpcode.AddI64 => {
				const lhs = slots[base + ib];
				const rhs = slots[base + ic];
				const sum = int64Bits((lhs.intVal as uint64) + (rhs.intVal as uint64));
				if ((sum ^ lhs.intVal) >= 0 || (sum ^ rhs.intVal) >= 0) { setRegInt(vm, base + ia, sum);
				} else { vm.ip = ip; vmError(vm, "over- or underflow"); break; }
			},
			RaiserOpcode.SubI64 => {
				const lhs = slots[base + ib];
				const rhs = slots[base + ic];
				const diff = int64Bits((lhs.intVal as uint64) - (rhs.intVal as uint64));
				if ((diff ^ lhs.intVal) >= 0 || (diff ^ ~rhs.intVal) >= 0) { setRegInt(vm, base + ia, diff);
				} else { vm.ip = ip; vmError(vm, "over- or underflow"); break; }
			},
			RaiserOpcode.MulI64 => {
				const lhs = slots[base + ib];
				const rhs = slots[base + ic];
				if (mulOverflowsI64(lhs.intVal, rhs.intVal)) { vm.ip = ip; vmError(vm, "over- or underflow"); break;
				} else { setRegInt(vm, base + ia, int64Bits((lhs.intVal as uint64) * (rhs.intVal as uint64))); }
			},
			RaiserOpcode.DivI64 => {
				const lhs = slots[base + ib];
				const rhs = slots[base + ic];
				if (rhs.intVal == 0) { vm.ip = ip; vmError(vm, "integer division by zero"); break;
				} else if (rhs.intVal == -1) {
					if (lhs.intVal == INT64_LOW) { vm.ip = ip; vmError(vm, "over- or underflow"); break;
					} else { setRegInt(vm, base + ia, -lhs.intVal); }
				} else {
					setRegInt(vm, base + ia, lhs.intVal / rhs.intVal);
				}
			},
			RaiserOpcode.ModI64 => {
				if (slots[base + ic].intVal == 0) { vm.ip = ip; vmError(vm, "integer modulo by zero"); break;
				} else {
					setRegInt(vm, base + ia, slots[base + ic].intVal == -1 ? 0 : slots[base + ib].intVal % slots[base + ic].intVal);
				}
			},
			RaiserOpcode.DivU64 => {
				if (slots[base + ic].intVal == 0) { vm.ip = ip; vmError(vm, "integer division by zero"); break;
				} else {
					setRegInt(vm, base + ia, int64Bits((slots[base + ib].intVal as uint64) / (slots[base + ic].intVal as uint64)));
				}
			},
			RaiserOpcode.ModU64 => {
				if (slots[base + ic].intVal == 0) { vm.ip = ip; vmError(vm, "integer modulo by zero"); break;
				} else {
					setRegInt(vm, base + ia, int64Bits((slots[base + ib].intVal as uint64) % (slots[base + ic].intVal as uint64)));
				}
			},
			RaiserOpcode.AddU64 => {
				setRegInt(vm, base + ia, int64Bits((slots[base + ib].intVal as uint64) + (slots[base + ic].intVal as uint64)));
			},
			RaiserOpcode.SubU64 => {
				setRegInt(vm, base + ia, int64Bits((slots[base + ib].intVal as uint64) - (slots[base + ic].intVal as uint64)));
			},
			RaiserOpcode.MulU64 => {
				setRegInt(vm, base + ia, int64Bits((slots[base + ib].intVal as uint64) * (slots[base + ic].intVal as uint64)));
			},
			RaiserOpcode.AddrReg => {
				setRegRef(vm, base + ia, RaiserValueKind.RegAddr, (base + ib) as int64);
			},
			RaiserOpcode.AddrGlobal => {
				setRegRef(vm, base + ia, RaiserValueKind.GlobalAddr, (ib * 256 + ic) as int64);
			},
			RaiserOpcode.InstanceOf => {
				const held = slots[base + ib];
				const key = constStringText(getFuncConst(func, ic));
				setRegBool(vm, base + ia, held.kind == RaiserValueKind.Object && raiserIsInstance(vm.objectHeap.objects[held.intVal].classType, key));
			},
			RaiserOpcode.ObjConv => {
				const held = slots[base + ia];
				if (held.kind != RaiserValueKind.Nil) {
					const classType = held.kind == RaiserValueKind.Object ? vm.objectHeap.objects[held.intVal].classType : RAISER_NO_CLASS;
					if (!raiserIsInstance(classType, constStringText(getFuncConst(func, ib)))) {
						vm.ip = ip; vmError(vm, "invalid object conversion: " + (classType.name != "" ? classType.name : "<untyped>") + " is not " + constStringText(getFuncConst(func, ic))); break;
					}
				}
			},
			RaiserOpcode.SameLoc => {
				const l = slots[base + ib];
				const r = slots[base + ic];
				setRegBool(vm, base + ia, l.kind == r.kind && (l.kind == RaiserValueKind.String ? vmText(vm, l) == vmText(vm, r) : l.intVal == r.intVal && l.floatVal == r.floatVal));
			},
			RaiserOpcode.NegI64 => {
				const val = slots[base + ib];
				if (val.intVal == INT64_LOW) { vm.ip = ip; vmError(vm, "over- or underflow"); break;
				} else { setRegInt(vm, base + ia, -val.intVal); }
			},
			RaiserOpcode.BeqI64 => {
				if (slots[base + ia].intVal == slots[base + ib].intVal) ip = ip + (ic as int32);
			},
			RaiserOpcode.BneI64 => {
				if (slots[base + ia].intVal != slots[base + ib].intVal) ip = ip + (ic as int32);
			},
			RaiserOpcode.BeqI64Imm => {
				if (slots[base + ia].intVal == immValue(ib)) ip = ip + (ic as int32);
			},
			RaiserOpcode.BneI64Imm => {
				if (slots[base + ia].intVal != immValue(ib)) ip = ip + (ic as int32);
			},
			RaiserOpcode.BltI64Imm => {
				if (slots[base + ia].intVal < immValue(ib)) ip = ip + (ic as int32);
			},
			RaiserOpcode.BleI64Imm => {
				if (slots[base + ia].intVal <= immValue(ib)) ip = ip + (ic as int32);
			},
			RaiserOpcode.BgtI64Imm => {
				if (slots[base + ia].intVal > immValue(ib)) ip = ip + (ic as int32);
			},
			RaiserOpcode.BgeI64Imm => {
				if (slots[base + ia].intVal >= immValue(ib)) ip = ip + (ic as int32);
			},
			RaiserOpcode.BTruthy => {
				if (raiserToBool(vm.arrayHeap, slots[base + ia])) ip = ip + (ic as int32);
			},
			RaiserOpcode.BltI64 => {
				if (slots[base + ia].intVal < slots[base + ib].intVal) ip = ip + (ic as int32);
			},
			RaiserOpcode.BleI64 => {
				if (slots[base + ia].intVal <= slots[base + ib].intVal) ip = ip + (ic as int32);
			},
			RaiserOpcode.BltU64 => {
				if ((slots[base + ia].intVal as uint64) < (slots[base + ib].intVal as uint64)) ip = ip + (ic as int32);
			},
			RaiserOpcode.BleU64 => {
				if ((slots[base + ia].intVal as uint64) <= (slots[base + ib].intVal as uint64)) ip = ip + (ic as int32);
			},
			RaiserOpcode.BgtI64 => {
				if (slots[base + ia].intVal > slots[base + ib].intVal) ip = ip + (ic as int32);
			},
			RaiserOpcode.BgeI64 => {
				if (slots[base + ia].intVal >= slots[base + ib].intVal) ip = ip + (ic as int32);
			},
			RaiserOpcode.BitAnd => {
				setRegInt(vm, base + ia, slots[base + ib].intVal & slots[base + ic].intVal);
			},
			RaiserOpcode.BitOr => {
				setRegInt(vm, base + ia, slots[base + ib].intVal | slots[base + ic].intVal);
			},
			RaiserOpcode.BitXor => {
				setRegInt(vm, base + ia, slots[base + ib].intVal ^ slots[base + ic].intVal);
			},
			RaiserOpcode.BitNot => {
				const val = slots[base + ib];
				setRegInt(vm, base + ia, ~val.intVal);
			},
			RaiserOpcode.ShiftLeft => {
				const count = (slots[base + ic].intVal & 63) as uint64;
				setRegInt(vm, base + ia, int64Bits((slots[base + ib].intVal as uint64) << count));
			},
			RaiserOpcode.ShiftRight => {
				setRegInt(vm, base + ia, slots[base + ib].intVal >> (slots[base + ic].intVal & 63));
			},
			RaiserOpcode.NarrowU => {
				const val = slots[base + ia];
				const width = ib as int64;
				setRegInt(vm, base + ia, val.intVal & (((1 as int64) << width) - 1));
			},
			RaiserOpcode.NarrowS => {
				const val = slots[base + ia];
				const half = (1 as int64) << ((ib as int64) - 1);
				const low = ic == 1 ? 0 : -half;
				if (val.intVal < low || val.intVal >= low + 2 * half) { vm.ip = ip; vmError(vm, "over- or underflow"); break; }
			},
			RaiserOpcode.SignExtend => {
				const val = slots[base + ia];
				const imm = 64 - (ib as int64);
				const raised = int64Bits((val.intVal as uint64) << (imm as uint64));
				setRegInt(vm, base + ia, raised >> imm);
			},
			RaiserOpcode.ShiftRightU => {
				const count = (slots[base + ic].intVal & 63) as uint64;
				setRegInt(vm, base + ia, int64Bits((slots[base + ib].intVal as uint64) >> count));
			},
			RaiserOpcode.IsKind => {
				const v = slots[base + ib];
				setRegBool(vm, base + ia, (v.kind as number) == ic);
			},
			_ => {
				vm.ip = ip;
				if (vmStepHeap(vm, op, ia, ib, ic, func, pc, base)) {
					ip = vm.ip;
					if (vm.halted) break;
				} else {
					vmStepSlow(vm, op, ia, ib, ic, func, base, slots);
					if (vm.halted || vm.yielded) break;
					ip = vm.ip;
					base = vm.baseReg;
					if (vm.funcIdx != funcIdx) {
						funcIdx = vm.funcIdx;
						func = mod.functions[funcIdx];
						code = func.packed;
						if (code.length != func.code.length) assertPacked(func);
					}
					if (vm.regs != regs) {
						regs = vm.regs;
						slots = regs.slots;
					}
				}
			},
		}
	}
}

function vmStepHeap(vm: RaiserVM, op: RaiserOpcode, ia: int32, ib: int32, ic: int32, func: RaiserFunction, pc: int32, base: int32): boolean {
	match (op) {
		RaiserOpcode.AddrIndex => {
			vmHandleAddrIndex(vm, ia, ib, ic);
		},
		RaiserOpcode.AddrField => {
			const handle = vmHeapOperand(vm, getReg(vm, base + ib), RaiserValueKind.Object, "an object");
			if (!vm.halted) setReg(vm, base + ia, raiserFieldAddrAt(handle, getFuncConst(func, ic).intVal));
		},
		RaiserOpcode.LoadDeref => {
			vmHandleLoadDeref(vm, ia, ib, ic);
		},
		RaiserOpcode.StoreDeref => {
			vmHandleStoreDeref(vm, ia, ib, ic);
		},
		RaiserOpcode.Conv => {
			vmHandleConv(vm, ia, ib, ic);
		},
		RaiserOpcode.NewArray => {
			vmHandleNewArray(vm, ia, ib, ic);
		},
		RaiserOpcode.LoadIndex => {
			vmHandleLoadIndex(vm, ia, ib, ic);
		},
		RaiserOpcode.StoreIndex => {
			vmHandleStoreIndex(vm, ia, ib, ic);
		},
		RaiserOpcode.ArrayLen => {
			vmHandleArrayLen(vm, ia, ib, ic);
		},
		RaiserOpcode.ArrayPush => {
			vmHandleArrayPush(vm, ia, ib, ic);
		},
		RaiserOpcode.ArraySetLen => {
			vmHandleArraySetLen(vm, ia, ib, ic);
		},
		RaiserOpcode.ArraySlice => {
			vmHandleArraySlice(vm, ia, ib, ic);
		},
		RaiserOpcode.NewObject => {
			vmHandleNewObject(vm, ia, ib, func);
		},
		RaiserOpcode.LoadField => {
			vmHandleLoadField(vm, func, pc, ia, ib, ic);
		},
		RaiserOpcode.StoreField => {
			vmHandleStoreField(vm, func, pc, ia, ib, ic);
		},
		RaiserOpcode.ConcatStr => {
			vmHandleConcatStr(vm, ia, ib, ic);
		},
		RaiserOpcode.EqStr => {
			vmHandleEqStr(vm, ia, ib, ic);
		},
		RaiserOpcode.NeStr => {
			vmHandleNeStr(vm, ia, ib, ic);
		},
		RaiserOpcode.LtStr => {
			vmHandleLtStr(vm, ia, ib, ic);
		},
		RaiserOpcode.LeStr => {
			vmHandleLeStr(vm, ia, ib, ic);
		},
		RaiserOpcode.StrLen => {
			vmHandleStrLen(vm, ia, ib, ic);
		},
		RaiserOpcode.StrByteLen => {
			const value = vmText(vm, getReg(vm, vm.baseReg + ib)).byteLength;
			setRegInt(vm, vm.baseReg + ia, value);
		},
		RaiserOpcode.StrCharAt => {
			vmHandleStrCharAt(vm, ia, ib, ic);
		},
		RaiserOpcode.StrSlice => {
			vmHandleStrSlice(vm, ia, ib, ic);
		},
		RaiserOpcode.AddF64 => {
			vmHandleAddF64(vm, ia, ib, ic);
		},
		RaiserOpcode.SubF64 => {
			vmHandleSubF64(vm, ia, ib, ic);
		},
		RaiserOpcode.MulF64 => {
			vmHandleMulF64(vm, ia, ib, ic);
		},
		RaiserOpcode.DivF64 => {
			vmHandleDivF64(vm, ia, ib, ic);
		},
		RaiserOpcode.NegF64 => {
			vmHandleNegF64(vm, ia, ib, ic);
		},
		RaiserOpcode.BeqF64 => {
			vmCmpBranchF64(vm, ia, ib, ic, 0);
		},
		RaiserOpcode.BneF64 => {
			vmCmpBranchF64(vm, ia, ib, ic, 1);
		},
		RaiserOpcode.BltF64 => {
			vmCmpBranchF64(vm, ia, ib, ic, 2);
		},
		RaiserOpcode.BleF64 => {
			vmCmpBranchF64(vm, ia, ib, ic, 3);
		},
		RaiserOpcode.BgtF64 => {
			vmCmpBranchF64(vm, ia, ib, ic, 4);
		},
		RaiserOpcode.BgeF64 => {
			vmCmpBranchF64(vm, ia, ib, ic, 5);
		},
		_ => {
			return false;
		},
	}
	return true;
}

function vmStepSlow(vm: RaiserVM, op: RaiserOpcode, ia: int32, ib: int32, ic: int32, func: RaiserFunction, base: int32, slots: RaiserValue[]): void {
	match (op) {
		RaiserOpcode.Halt => {
			const haltVal = slots[base + ia];
			if (ib != 1 && strandFinish(vm, haltVal)) {
				vm.yielded = true;
			} else {
				finishProgram(vm, haltVal, ib == 1);
			}
		},
		RaiserOpcode.Print => {
			const val = slots[base + ia];
			const s = raiserToString(vm.arrayHeap, val);
			vm.output = `${vm.output}${s}\n`;
			const sink = vm.printSink;
			if (sink != null) sink(s);
		},
		RaiserOpcode.Call => {
			vmHandleCall(vm, ia, ib, ic);
		},
		RaiserOpcode.CallIndirect => {
			vmHandleCallIndirect(vm, ia, ib, ic);
		},
		RaiserOpcode.Ret => {
			vmHandleRet(vm, ia, ib, ic);
		},
		RaiserOpcode.CallHost => {
			vmHandleCallHost(vm, ia, ib, ic);
		},
		RaiserOpcode.Yield => {
			vm.yielded = true;
		},
		RaiserOpcode.Spawn => {
			const fut = vmSpawnClosure(vm, getReg(vm, base + ib));
			if (fut >= 0) setRegRef(vm, base + ia, RaiserValueKind.Future, fut);
		},
		RaiserOpcode.Await => {
			vmHandleAwait(vm, ia, ib, ic);
		},
		RaiserOpcode.Sleep => {
			vmHandleSleep(vm, ia, ib, ic);
		},
		RaiserOpcode.ModuleImport => {
			vmHandleModuleImport(vm, ia, ib * 256 + ic, func);
		},
		RaiserOpcode.FutureNew => {
			setRegRef(vm, base + ia, RaiserValueKind.Future, newFuture(vm));
		},
		RaiserOpcode.FutureSettle => {
			futureComplete(vm, getReg(vm, base + ia).intVal, getReg(vm, base + ib));
		},
		RaiserOpcode.FutureFail => {
			futureFail(vm, getReg(vm, base + ia).intVal, vmExceptionText(vm, getReg(vm, base + ib)), getReg(vm, base + ib));
		},
		RaiserOpcode.Try => {
			vm.safePoints.push(vm.ip - 1 + (ib * 256 + ic));
		},
		RaiserOpcode.Catch => {
			vmError(vm, "Catch is handler metadata and must never execute");
		},
		RaiserOpcode.Finally => {
			// Only reached when the guarded region completed without raising.
			popSafePoint(vm);
			enterFinally(vm, ia, FINALLY_NORMAL, raiserNil());
		},
		RaiserOpcode.FinallyEnd => {
			const kind = getReg(vm, base + ia);
			const held = getReg(vm, base + ia + 1);
			if (kind.kind != RaiserValueKind.Int) {
				vmError(vm, `FinallyEnd reached without its Finally: R[${ia}] holds no routing`);
			} else if (kind.intVal == FINALLY_RAISE) {
				copyValueInto(vm.currentException, held);
				unwindStep(vm);
			} else if (kind.intVal == FINALLY_RETURN) {
				vm.ip = held.intVal as int32;
			} else if (kind.intVal != FINALLY_NORMAL) {
				vmError(vm, `FinallyEnd: unknown routing ${kind.intVal}`);
			}
		},
		RaiserOpcode.Throw => {
			vmHandleThrow(vm, ia, ib, ic);
		},
		RaiserOpcode.Trap => {
			const bx = (ib * 256 + ic);
			const msg = bx < getFuncConstLen(func) ? constStringText(getFuncConst(func, bx)) : "trap: bad message constant";
			vmError(vm, msg);
		},
		_ => {
			vmError(vm, `Unknown opcode: ${op}`);
		},
	}
}

// --- Call/Ret handlers ---

function enterCallee(vm: RaiserVM, destReg: number, calleeFuncIdx: number): void {
	// Callee's base = right at args (R[dest+1..dest+N] become callee's R[0..N-1]),
	// so the arguments are never copied; only the frame record is written.
	const newBase = vm.baseReg + destReg + 1;
	const reserve = newBase + vm.mod.functions[calleeFuncIdx].maxRegs;
	if (vm.regs.slots.length < reserve) ensureSlots(vm.regs, reserve);

	const depth = vm.callStack.depth;
	if (depth == vm.callStack.items.length) {
		vm.callStack.items.push({ funcIdx: 0, returnIp: 0, returnReg: 0, baseReg: 0, spBase: 0 });
	}
	vm.callStack.items[depth].funcIdx = vm.funcIdx;
	vm.callStack.items[depth].returnIp = vm.ip;
	vm.callStack.items[depth].returnReg = (vm.baseReg + destReg) as int32;
	vm.callStack.items[depth].baseReg = vm.baseReg;
	vm.callStack.items[depth].spBase = vm.safePoints.length as int32;
	vm.callStack.depth = depth + 1;

	vm.baseReg = newBase as int32;
	vm.funcIdx = calleeFuncIdx as int32;
	vm.ip = 0;
}

function vmHandleCall(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vm.callStack.depth >= MAX_CALL_DEPTH) {
		vmError(vm, `call stack overflow (depth ${MAX_CALL_DEPTH})`); return;
	}
	const calleeFuncIdx = ib;
	if (calleeFuncIdx < 0 || calleeFuncIdx >= vm.mod.functions.length) {
		vmError(vm, `function index out of bounds: ${calleeFuncIdx}`); return;
	}
	enterCallee(vm, ia, calleeFuncIdx as number);
}

// Returning from the entry function of a strand or a module body ends that
// strand's work; a return inside a guarded region runs its `finally` first.
// True when this Ret was handled here, false when it pops an ordinary frame.
function vmRetSpecial(vm: RaiserVM, ia: int32): boolean {
	// Leaving a guarded region: its finally runs first and comes back here.
	const finIp = cleanUpOnReturn(vm);
	if (finIp >= 0) {
		vm.ip = finIp as int32;
		return true;
	}
	if (vm.callStack.depth > 0) return false;
	if (vm.current == vm.sched.modules.strand) {
		const at = vm.sched.modules.execBody;
		vm.sched.modules.execBody = -1;
		if (at >= 0) moduleExecBodyFulfilled(vm, at);
		moduleTaskContinue(vm);
		return true;
	}
	const body = moduleBodyOf(vm, vm.current);
	if (body >= 0) {
		moduleBodyFinish(vm, body, RaiserModuleJobKind.Fulfilled, raiserNil());
		return true;
	}
	// Top-level return — the strand is finished; the main one ends the
	// program, but only once the remaining strands have drained.
	const retVal = getReg(vm, vm.baseReg + ia);
	if (strandFinish(vm, retVal)) {
		vm.yielded = true;
		return true;
	}
	finishProgram(vm, retVal, false);
	return true;
}

function vmHandleRet(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const depth = vm.callStack.depth;
	// A frame with no handler of its own open returns without any bookkeeping.
	if (depth == 0 || vm.safePoints.length != vm.callStack.items[depth - 1].spBase) {
		if (vmRetSpecial(vm, ia)) return;
	}

	vm.callStack.depth = depth - 1;
	if (vm.safePoints.length != vm.callStack.items[depth - 1].spBase) {
		vm.safePoints.length = vm.callStack.items[depth - 1].spBase;
	}

	if (vm.baseReg + ia >= vm.regs.slots.length) throw slotOutside(vm.baseReg + ia);
	setReg(vm, vm.callStack.items[depth - 1].returnReg, vm.regs.slots[vm.baseReg + ia]);

	// No blanket frame-exit decref: the global register file is reused across
	// calls, so a callee slot may hold a stale handle from a prior frame that this
	// frame never owned — decref-ing the whole range over-decrefs it (UAF).
	// Reclamation instead happens lazily via setReg's decref-on-overwrite when the
	// slot is next written (frame reuse). Residual: a never-reused slot's ref lingers.

	vm.funcIdx = vm.callStack.items[depth - 1].funcIdx;
	vm.baseReg = vm.callStack.items[depth - 1].baseReg;
	vm.ip = vm.callStack.items[depth - 1].returnIp;
}

function vmHandleCallIndirect(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vm.callStack.depth >= MAX_CALL_DEPTH) {
		vmError(vm, `call stack overflow (depth ${MAX_CALL_DEPTH})`); return;
	}
	const funcIdxReg = getReg(vm, vm.baseReg + ib);
	if (funcIdxReg.kind != RaiserValueKind.Int) {
		vmError(vm, "indirect call target is not a function"); return;
	}
	const calleeFuncIdx = funcIdxReg.intVal;
	if (calleeFuncIdx < 0 || calleeFuncIdx >= vm.mod.functions.length) {
		vmError(vm, `function index out of bounds: ${calleeFuncIdx}`); return;
	}
	enterCallee(vm, ia, calleeFuncIdx as number);
}

// --- Array opcode handlers ---

function vmHandleNewArray(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const handle = heapAllocArray(vm.arrayHeap);
	const elemCount = ib;
	for (let i = 0; i < elemCount; i = i + 1) {
		const elem = getReg(vm, vm.baseReg + ia + 1 + i);
		heapArrayPush(vm.arrayHeap, handle, elem);
		vmIncref(vm, elem);
	}
	setRegRef(vm, vm.baseReg + ia, RaiserValueKind.Array, handle);
	vmMaybeCollect(vm);
}

function vmHeapOperand(vm: RaiserVM, v: RaiserValue, kind: RaiserValueKind, expected: string): int64 {
	if (v.kind == kind) return v.intVal;
	if (v.kind == RaiserValueKind.Nil) {
		vmError(vm, "attempt to access a nil address");
	} else {
		vmError(vm, `expected ${expected}, got value kind ${v.kind}`);
	}
	return -1;
}

function vmElemIndex(vm: RaiserVM, handle: int64, idx: int64): boolean {
	if (handle < 0 || handle >= vm.arrayHeap.arrays.length) {
		vmError(vm, `array handle out of bounds: ${handle}`); return false;
	}
	const arrLen = heapArrayLen(vm.arrayHeap, handle);
	if (idx < 0 || idx >= arrLen) {
		vmError(vm, `array index out of bounds: ${idx} (length ${arrLen})`); return false;
	}
	return true;
}

function vmHandleAddrIndex(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const handle = vmHeapOperand(vm, getReg(vm, vm.baseReg + ib), RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	const idx = getReg(vm, vm.baseReg + ic).intVal;
	if (!vmElemIndex(vm, handle, idx)) return;
	const data = vm.arrayHeap.arrays[handle];
	if (data.viewOff >= 0) {
		setReg(vm, vm.baseReg + ia, raiserElemAddr(data.items[0].intVal, data.viewOff + idx));
		return;
	}
	setReg(vm, vm.baseReg + ia, raiserElemAddr(handle, idx));
}

function vmHandleLoadDeref(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const ptr = getReg(vm, vm.baseReg + ib);
	let held = ptr;
	if (ptr.kind == RaiserValueKind.RegAddr) {
		held = getReg(vm, ptr.intVal as number);
	} else if (ptr.kind == RaiserValueKind.GlobalAddr) {
		held = vm.globals[ptr.intVal];
	} else if (ptr.kind == RaiserValueKind.ElemAddr) {
		if (!vmElemIndex(vm, ptr.intVal, ptr.floatVal as int64)) return;
		held = heapArrayGet(vm.arrayHeap, ptr.intVal, ptr.floatVal as int64);
	} else if (ptr.kind == RaiserValueKind.FieldAddr) {
		held = heapObjectGetField(vm.objectHeap, ptr.intVal, fieldAddrName(ptr));
	} else if (ptr.kind == RaiserValueKind.Nil) {
		vmError(vm, "attempt to read through a nil pointer"); return;
	}
	const dst = getReg(vm, vm.baseReg + ia);
	vmIncref(vm, held);
	vmDecref(vm, dst);
	copyValueInto(dst, held);
}

function vmHandleStoreDeref(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const ptr = getReg(vm, vm.baseReg + ia);
	const val = getReg(vm, vm.baseReg + ic);
	if (ptr.kind == RaiserValueKind.RegAddr || ptr.kind == RaiserValueKind.GlobalAddr) {
		const dst = ptr.kind == RaiserValueKind.RegAddr ? getReg(vm, ptr.intVal as number) : vm.globals[ptr.intVal];
		vmIncref(vm, val);
		vmDecref(vm, dst);
		copyValueInto(dst, val);
	} else if (ptr.kind == RaiserValueKind.ElemAddr) {
		const idx = ptr.floatVal as int64;
		if (!vmElemIndex(vm, ptr.intVal, idx)) return;
		vmIncref(vm, val);
		vmDecref(vm, heapArrayGet(vm.arrayHeap, ptr.intVal, idx));
		heapArraySet(vm.arrayHeap, ptr.intVal, idx, val);
	} else if (ptr.kind == RaiserValueKind.FieldAddr) {
		vmIncref(vm, val);
		vmDecref(vm, heapObjectGetField(vm.objectHeap, ptr.intVal, fieldAddrName(ptr)));
		heapObjectSetField(vm.objectHeap, ptr.intVal, fieldAddrName(ptr), val);
	} else if (ptr.kind == RaiserValueKind.Nil) {
		vmError(vm, "attempt to write through a nil pointer");
	} else {
		vmError(vm, `cannot write through a value of kind ${ptr.kind}: it is not a location`);
	}
}

function vmHandleLoadIndex(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getReg(vm, vm.baseReg + ib);
	const idxVal = getReg(vm, vm.baseReg + ic);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
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
	const dst = getReg(vm, vm.baseReg + ia);
	vmIncref(vm, elem);
	vmDecref(vm, dst);
	copyValueInto(dst, elem);
}

function vmHandleStoreIndex(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getReg(vm, vm.baseReg + ia);
	const idxVal = getReg(vm, vm.baseReg + ib);
	const val = getReg(vm, vm.baseReg + ic);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
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

function vmHandleArrayLen(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getReg(vm, vm.baseReg + ib);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	if (handle < 0 || handle >= vm.arrayHeap.arrays.length) {
		vmError(vm, `array handle out of bounds: ${handle}`); return;
	}
	const len = heapArrayLen(vm.arrayHeap, handle);
	setRegInt(vm, vm.baseReg + ia, len as int64);
}

function vmHandleArrayPush(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getReg(vm, vm.baseReg + ia);
	const val = getReg(vm, vm.baseReg + ib);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	if (handle < 0 || handle >= vm.arrayHeap.arrays.length) {
		vmError(vm, `array handle out of bounds: ${handle}`); return;
	}
	if (heapArrayIsView(vm.arrayHeap, handle)) {
		vmError(vm, "cannot push to a slice"); return;
	}
	heapArrayPush(vm.arrayHeap, handle, val);
	vmIncref(vm, val);
}

function vmHandleArraySetLen(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getReg(vm, vm.baseReg + ia);
	const lenVal = getReg(vm, vm.baseReg + ib);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	if (handle < 0 || handle >= vm.arrayHeap.arrays.length) {
		vmError(vm, `array handle out of bounds: ${handle}`); return;
	}
	if (lenVal.kind != RaiserValueKind.Int) {
		vmError(vm, `ArraySetLen expected an integer length, got kind ${lenVal.kind}`); return;
	}
	if (ic == 1) {
		if (lenVal.intVal < 0) vmError(vm, `value ${lenVal.intVal} not in range 0 .. 9223372036854775807`);
		else if (lenVal.intVal > MAX_ARRAY_COUNT) vmError(vm, "over- or underflow");
		return;
	}
	if (heapArrayIsView(vm.arrayHeap, handle)) {
		vmError(vm, "cannot set the length of a slice"); return;
	}
	heapArraySetLen(vm.arrayHeap, handle, lenVal.intVal);
}

function vmHandleArraySlice(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const srcVal = getReg(vm, vm.baseReg + ib);
	const start = getReg(vm, vm.baseReg + ic).intVal;
	const end = getReg(vm, vm.baseReg + ic + 1).intVal;
	const handle = vmHeapOperand(vm, srcVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	if (handle < 0 || handle >= vm.arrayHeap.arrays.length) {
		vmError(vm, `array handle out of bounds: ${handle}`); return;
	}
	const len = heapArrayLen(vm.arrayHeap, handle);
	if (end != start && (start < 0 || end < start || end > len)) {
		vmError(vm, `slice ${start}..${end} out of bounds (length ${len})`); return;
	}
	let base = srcVal;
	let off = start;
	const data = vm.arrayHeap.arrays[handle];
	if (data.viewOff >= 0) {
		base = data.items[0];
		off = data.viewOff + start;
	}
	const view = heapAllocView(vm.arrayHeap, base, off, (end - start) as int32);
	vmIncref(vm, base);
	setRegRef(vm, vm.baseReg + ia, RaiserValueKind.Array, view);
	vmMaybeCollect(vm);
}

// --- Object opcode handlers ---

function vmHandleNewObject(vm: RaiserVM, ia: int32, ib: int32, func: RaiserFunction): void {
	const handle = heapAllocObject(vm.objectHeap);
	if (ib > 0) vm.objectHeap.objects[handle].classType = func.classTypes[ib - 1];
	setRegRef(vm, vm.baseReg + ia, RaiserValueKind.Object, handle);
	vmMaybeCollect(vm);
}

function vmHandleLoadField(vm: RaiserVM, func: RaiserFunction, pc: int32, ia: int32, ib: int32, ic: int32): void {
	const objVal = getReg(vm, vm.baseReg + ib);
	const handle = vmHeapOperand(vm, objVal, RaiserValueKind.Object, "an object");
	if (vm.halted) return;
	if (handle < 0 || handle >= vm.objectHeap.objects.length) {
		vmError(vm, `object handle out of bounds: ${handle}`); return;
	}
	const obj = vm.objectHeap.objects[handle];
	const fields = obj.fields;

	// MIC: try cached index first
	let idx = func.fieldCache[pc];
	if (idx >= 0 && idx < fields.length) {
		if (fields[idx].name == func.names[ic]) {
			// Cache hit — O(1) access
			setReg(vm, vm.baseReg + ia, fields[idx].value);
			return;
		}
	}

	// Cache miss — linear scan, then update cache
	const fieldName = func.names[ic];
	let fi = 0;
	while (fi < fields.length) {
		if (fields[fi].name == fieldName) {
			func.fieldCache[pc] = fi;
			setReg(vm, vm.baseReg + ia, fields[fi].value);
			return;
		}
		fi = fi + 1;
	}
	// Field not found — load nil
	const dst = getReg(vm, vm.baseReg + ia);
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Nil;
	dst.intVal = 0;
	dst.floatVal = 0.0;
}

function vmHandleStoreField(vm: RaiserVM, func: RaiserFunction, pc: int32, ia: int32, ib: int32, ic: int32): void {
	const objVal = getReg(vm, vm.baseReg + ia);
	const handle = vmHeapOperand(vm, objVal, RaiserValueKind.Object, "an object");
	if (vm.halted) return;
	if (handle < 0 || handle >= vm.objectHeap.objects.length) {
		vmError(vm, `object handle out of bounds: ${handle}`); return;
	}
	const obj = vm.objectHeap.objects[handle];
	const fields = obj.fields;
	const val = getReg(vm, vm.baseReg + ic);

	// MIC: try cached index first
	let idx = func.fieldCache[pc];
	if (idx >= 0 && idx < fields.length) {
		if (fields[idx].name == func.names[ib]) {
			// Cache hit — O(1) update
			vmIncref(vm, val);
			vmDecref(vm, fields[idx].value);
			copyValueInto(fields[idx].value, val);
			return;
		}
	}

	// Cache miss — linear scan, then update cache
	const fieldName = func.names[ib];
	let fi = 0;
	while (fi < fields.length) {
		if (fields[fi].name == fieldName) {
			func.fieldCache[pc] = fi;
			vmIncref(vm, val);
			vmDecref(vm, fields[fi].value);
			copyValueInto(fields[fi].value, val);
			return;
		}
		fi = fi + 1;
	}
	// New field — append
	vmIncref(vm, val);
	const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal };
	const field: RaiserObjectField = { name: fieldName, value: copy };
	fields.push(field);
	func.fieldCache[pc] = (fields.length - 1) as int32;
}

// --- String opcode handlers ---
// Every handler reads its source text before it writes the destination: the
// destination write releases the old value, which may be the source's own string.

function vmHandleConcatStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const lhs = getReg(vm, vm.baseReg + ib);
	const rhs = getReg(vm, vm.baseReg + ic);
	setRegString(vm, vm.baseReg + ia, raiserToString(vm.arrayHeap, lhs) + raiserToString(vm.arrayHeap, rhs));
}

function vmHandleEqStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vmText(vm, getReg(vm, vm.baseReg + ia)) == vmText(vm, getReg(vm, vm.baseReg + ib))) {
		vm.ip = vm.ip + (ic as int32);
	}
}

function vmHandleNeStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vmText(vm, getReg(vm, vm.baseReg + ia)) != vmText(vm, getReg(vm, vm.baseReg + ib))) {
		vm.ip = vm.ip + (ic as int32);
	}
}

function vmHandleLtStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vmText(vm, getReg(vm, vm.baseReg + ia)) < vmText(vm, getReg(vm, vm.baseReg + ib))) {
		vm.ip = vm.ip + (ic as int32);
	}
}

function vmHandleLeStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vmText(vm, getReg(vm, vm.baseReg + ia)) <= vmText(vm, getReg(vm, vm.baseReg + ib))) {
		vm.ip = vm.ip + (ic as int32);
	}
}

// --- String method handlers ---

function vmHandleStrLen(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const length = vmText(vm, getReg(vm, vm.baseReg + ib)).length;
	setRegInt(vm, vm.baseReg + ia, length);
}

function vmHandleStrCharAt(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const text = vmText(vm, getReg(vm, vm.baseReg + ib));
	const i = getReg(vm, vm.baseReg + ic).intVal;
	setRegString(vm, vm.baseReg + ia, i >= 0 && i < text.length ? text.slice(i as int32, (i + 1) as int32) : "");
}

function vmHandleStrSlice(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const text = vmText(vm, getReg(vm, vm.baseReg + ib));
	const start = getReg(vm, vm.baseReg + ic).intVal;
	const end = getReg(vm, vm.baseReg + ic + 1).intVal;
	setRegString(vm, vm.baseReg + ia, text.slice(start as int32, end as int32));
}

// --- Float value extraction (handles int-to-float promotion) ---

function asNum(val: RaiserValue): number {
	if (val.kind == RaiserValueKind.Float) return val.floatVal;
	return val.intVal as number;
}

function floatFitsSigned(f: float64, bits: int32): boolean {
	if (bits == 64) return f >= -9223372036854775808.0 && f < 9223372036854775808.0;
	const limit = Math.pow(2, (bits - 1) as float64);
	return f > -limit - 1 && f < limit;
}

function floatFitsUnsigned(f: float64, bits: int32): boolean {
	return f > -1.0 && f < Math.pow(2, bits as float64);
}

function convToFloat(src: RaiserValue, fromUnsigned: boolean, toFloat32: boolean): number {
	if (src.kind != RaiserValueKind.Int) return toFloat32 ? (asNum(src) as float32) as float64 : asNum(src);
	if (fromUnsigned) return toFloat32 ? ((src.intVal as uint64) as float32) as float64 : (src.intVal as uint64) as float64;
	return toFloat32 ? (src.intVal as float32) as float64 : src.intVal as float64;
}

function vmConvToChar(vm: RaiserVM, ia: int32, ib: int32, ic: int32, src: RaiserValue, fromUnsigned: boolean): void {
	if (src.kind == RaiserValueKind.Float) {
		if (!floatFitsUnsigned(src.floatVal, 8)) {
			vmError(vm, `value ${src.floatVal} not in range 0 .. 255`);
			return;
		}
		setRegInt(vm, vm.baseReg + ia, src.floatVal as int64);
		return;
	}
	if (src.intVal < 0 || src.intVal > 255) {
		vmError(vm, `value ${fromUnsigned ? `${src.intVal as uint64}` : `${src.intVal}`} not in range 0 .. 255`);
		return;
	}
	setRegInt(vm, vm.baseReg + ia, src.intVal);
}

function vmHandleConv(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const src = getReg(vm, vm.baseReg + ib);
	const cls = convTarget(ic);
	const fromUnsigned = convSource(ic) == (RaiserConvClass.U64 as int32);
	if (cls == RaiserConvClass.F64Bits) {
		setRegInt(vm, vm.baseReg + ia, int64Bits(msFloat64Bits(asNum(src))));
		return;
	}
	if (cls == RaiserConvClass.I32Wrap) {
		setRegInt(vm, vm.baseReg + ia, msToInt32(asNum(src)) as int64);
		return;
	}
	if (cls == RaiserConvClass.HandleBits) {
		if (src.kind == RaiserValueKind.Nil) {
			setRegInt(vm, vm.baseReg + ia, 0);
		} else if (src.kind == RaiserValueKind.Object || src.kind == RaiserValueKind.Array) {
			setRegInt(vm, vm.baseReg + ia, src.intVal);
		} else {
			vmError(vm, `no identity bits for a value of kind ${src.kind}`);
		}
		return;
	}
	if (cls == RaiserConvClass.F64 || cls == RaiserConvClass.F32) {
		setRegFloat(vm, vm.baseReg + ia, convToFloat(src, fromUnsigned, cls == RaiserConvClass.F32));
		return;
	}
	if (cls == RaiserConvClass.Str && convSource(ic) == (RaiserConvClass.Char as int32)) {
		setRegString(vm, vm.baseReg + ia, fromCodePoint(src.intVal >= 0 && src.intVal < 0x80 ? src.intVal as int32 : 0xFFFD));
		return;
	}
	if (cls == RaiserConvClass.Str) {
		setRegString(vm, vm.baseReg + ia, fromUnsigned && src.kind == RaiserValueKind.Int ? `${src.intVal as uint64}` : raiserToString(vm.arrayHeap, src));
		return;
	}
	if (cls == RaiserConvClass.Char) {
		vmConvToChar(vm, ia, ib, ic, src, fromUnsigned);
		return;
	}
	const bits = convClassBits(cls);
	const signed = convClassSigned(cls);
	if (src.kind == RaiserValueKind.Float && !signed && !floatFitsUnsigned(src.floatVal, bits)) {
		const top: uint64 = bits == 64 ? 18446744073709551615 : ((1 as uint64) << (bits as uint64)) - 1;
		vmError(vm, `value ${src.floatVal} not in range 0 .. ${top}`);
		return;
	}
	if (cls == RaiserConvClass.U64 && src.kind == RaiserValueKind.Float && src.floatVal >= 9223372036854775808.0) {
		setRegInt(vm, vm.baseReg + ia, int64Bits(src.floatVal as uint64));
		return;
	}
	const hi: int64 = bits == 64
		? 9223372036854775807
		: ((1 as int64) << ((bits - 1) as int64)) - 1;
	const lo: int64 = -hi - 1;
	if (src.kind == RaiserValueKind.Float && signed && !floatFitsSigned(src.floatVal, bits)) {
		vmError(vm, `value ${src.floatVal} not in range ${lo} .. ${hi}`);
		return;
	}
	if (src.kind == RaiserValueKind.Int && signed && fromUnsigned && src.intVal < 0) {
		vmError(vm, `value ${src.intVal as uint64} not in range ${lo} .. ${hi}`);
		return;
	}
	const whole: int64 = src.kind == RaiserValueKind.Float ? (src.floatVal as int64) : src.intVal;
	if (bits == 64) {
		setRegInt(vm, vm.baseReg + ia, whole);
		return;
	}
	if (signed) {
		if (whole < lo || whole > hi) {
			vmError(vm, `value ${whole} not in range ${lo} .. ${hi}`);
			return;
		}
		setRegInt(vm, vm.baseReg + ia, whole);
		return;
	}
	setRegInt(vm, vm.baseReg + ia, whole & (((1 as int64) << (bits as int64)) - 1));
}

// --- Float arithmetic handlers ---

function vmHandleAddF64(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const lhs = getReg(vm, vm.baseReg + ib);
	const rhs = getReg(vm, vm.baseReg + ic);
	const dst = getReg(vm, vm.baseReg + ia);
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) + asNum(rhs);
	dst.intVal = 0;
}

function vmHandleSubF64(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const lhs = getReg(vm, vm.baseReg + ib);
	const rhs = getReg(vm, vm.baseReg + ic);
	const dst = getReg(vm, vm.baseReg + ia);
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) - asNum(rhs);
	dst.intVal = 0;
}

function vmHandleMulF64(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const lhs = getReg(vm, vm.baseReg + ib);
	const rhs = getReg(vm, vm.baseReg + ic);
	const dst = getReg(vm, vm.baseReg + ia);
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) * asNum(rhs);
	dst.intVal = 0;
}

function vmHandleDivF64(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const lhs = getReg(vm, vm.baseReg + ib);
	const rhs = getReg(vm, vm.baseReg + ic);
	const dst = getReg(vm, vm.baseReg + ia);
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = asNum(lhs) / asNum(rhs);
	dst.intVal = 0;
}

function vmHandleNegF64(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const src = getReg(vm, vm.baseReg + ib);
	const dst = getReg(vm, vm.baseReg + ia);
	vmDecref(vm, dst);
	dst.kind = RaiserValueKind.Float;
	dst.floatVal = -asNum(src);
	dst.intVal = 0;
}

// --- Float compare-branch handlers ---

function vmCmpBranchF64(vm: RaiserVM, ia: int32, ib: int32, ic: int32, cmpOp: number): void {
	const l = asNum(getReg(vm, vm.baseReg + ia));
	const r = asNum(getReg(vm, vm.baseReg + ib));
	let cond = false;
	if (cmpOp == 0) { cond = l == r; }
	else if (cmpOp == 1) { cond = l != r; }
	else if (cmpOp == 2) { cond = l < r; }
	else if (cmpOp == 3) { cond = l <= r; }
	else if (cmpOp == 4) { cond = l > r; }
	else if (cmpOp == 5) { cond = l >= r; }
	if (cond) { vm.ip = vm.ip + (ic as int32); }
}

// --- Bitwise handlers ---

// using int64_t casts — MetaScript fallback not needed.

// --- CallHost handler ---
// Generic name-resolved native call. The only host-call mechanism. Lookup
// is O(n) over the registry, but n is small (~20-200 host fns) and the
// registered wrappers (in src/compiler/meta/hostTable.ms) own all
// type-specific marshalling.

function vmHandleCallHost(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const base = vm.baseReg;
	const func = getModuleFunc(vm.mod, vm.funcIdx);
	const nameConst = getFuncConst(func, ib);
	if (nameConst.kind != RaiserValueKind.String) {
		vmError(vm, `CallHost expected string constant at index ${ib}, got kind ${nameConst.kind}`);
		return;
	}
	const name = constStringText(nameConst);

	const fn = lookupHostFn(name);
	if (fn == (null as unknown as RaiserHostFn)) {
		vmError(vm, `Unknown host function: ${name}`);
		return;
	}
	if (vm.hostCallsRestricted && !hostFnAllowedInRestrictedMode(name)) {
		vmError(vm, `Restricted dependency compile-time code '${vm.hostPolicySource}' cannot call host function '${name}'`);
		return;
	}

	// Collect args from R[A+1] .. R[A+C]
	const args: RaiserValue[] = [];
	let i = 0;
	while (i < ic) {
		const argBox = raiserNil();
		copyValueInto(argBox, getReg(vm, base + ia + 1 + i));
		args.push(argBox);
		i = i + 1;
	}

	// Save/restore so a bridge that re-enters a nested VM leaves the outer
	// VM's heaps active when it resumes.
	const prevObjHeap = activeHostObjectHeap();
	const prevArrHeap = activeHostArrayHeap();
	const prevArgv = activeProgramArgv();
	setActiveHostHeaps(vm.objectHeap, vm.arrayHeap);
	setActiveProgramArgv(vm.programArgv);
	const outerFloor = vm.frameFloor;
	const suspended = vm.suspendedRuns.length;
	vm.frameFloor = vm.regs.slots.length;
	const result = fn(args);
	if (vm.suspendedRuns.length > suspended) {
		resumeRun(vm, vm.suspendedRuns[suspended]);
		vm.suspendedRuns.shrink(suspended);
	}
	vm.frameFloor = outerFloor;
	if (prevObjHeap != null && prevArrHeap != null) {
		setActiveHostHeaps(prevObjHeap, prevArrHeap);
	}
	setActiveProgramArgv(prevArgv);

	const fatal = hostRaiseIsFatal();
	const raised = takeHostRaise();
	if (raised != null) {
		if (fatal) {
			vmError(vm, raised);
			return;
		}
		copyValueInto(vm.currentException, heapAllocString(vm.arrayHeap, raised));
		unwindStep(vm);
		return;
	}

	const dst = getReg(vm, base + ia);
	vmIncref(vm, result);
	vmDecref(vm, dst);
	copyValueInto(dst, result);
}

// --- Stack trace ---

export function vmDumpStack(vm: RaiserVM): string {
	let trace = "Trace:";
	// Walk call stack from bottom (oldest) to top (newest)
	let i = 0;
	while (i < vm.callStack.depth) {
		const frame = vm.callStack.items[i];
		const func = getModuleFunc(vm.mod, frame.funcIdx);
		const ln = func.lines[frame.returnIp > 0 ? frame.returnIp - 1 : 0];
		if (ln > 0) {
			trace = `${trace}\n  line ${ln} in ${func.name}`;
		} else {
			trace = `${trace}\n  ${func.name}`;
		}
		i = i + 1;
	}
	// Current frame (top of stack)
	const curFunc = getModuleFunc(vm.mod, vm.funcIdx);
	const curIp = vm.ip > 0 ? vm.ip - 1 : 0;
	if (curIp < curFunc.lines.length) {
		const curLn = curFunc.lines[curIp];
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
		[raiserInt(a as int64), raiserInt(b as int64)]
	));
}

// --- Tests ---
test "the host clock advances across a host wait" {
	const before = msMonoTimeMs();
	msSleepMs(20);
	assert msMonoTimeMs() - before >= 20;
}

test "halt returns constant" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(42)]
	));
	assert vm.exitValue.intVal == 42;
}

test "a register keeps its box: ops write into it, and a string left in it is cleared" {
	const vm = createVM(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Move, 1, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 3, 1),
			raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
			raiserABC(RaiserOpcode.AddI64, 3, 0, 1),
			raiserABC(RaiserOpcode.AddI64, 0, 0, 0),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(7), raiserConstString("old")]
	));
	const r0 = vm.regs.slots[0];
	const r1 = vm.regs.slots[1];
	const r2 = vm.regs.slots[2];
	const r3 = vm.regs.slots[3];
	execLoop(vm);
	assert r0.intVal == 14;
	assert r1.intVal == 7;
	assert r2.intVal == 14;
	assert r3.kind == RaiserValueKind.Int && r3.intVal == 14;
}

function execConv(value: RaiserValue, cls: RaiserConvClass, from: int32 = -1): RaiserVM {
	return execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Conv, 1, 0, convOperand(cls, from)),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[value]
	));
}

test "a float converted to a signed integer out of its range stops, as on C" {
	assert execConv(raiserFloat(1e19), RaiserConvClass.I64).error.indexOf("not in range") >= 0;
	const i8 = execConv(raiserFloat(128.0), RaiserConvClass.I8);
	assert i8.error.indexOf("value 128 not in range -128 .. 127") >= 0;
	assert execConv(raiserFloat(0.0 / 0.0), RaiserConvClass.I32).error.indexOf("not in range") >= 0;
}

test "a float converted to an unsigned integer out of its range stops, as on C and JS" {
	assert execConv(raiserFloat(-1.0), RaiserConvClass.U8).error == "value -1 not in range 0 .. 255";
	assert execConv(raiserFloat(256.0), RaiserConvClass.U8).error == "value 256 not in range 0 .. 255";
	assert execConv(raiserFloat(65536.5), RaiserConvClass.U16).error == "value 65536.5 not in range 0 .. 65535";
	assert execConv(raiserFloat(0.0 / 0.0), RaiserConvClass.U32).error == "value NaN not in range 0 .. 4294967295";
	assert execConv(raiserFloat(1.0 / 0.0), RaiserConvClass.U64).error == "value Infinity not in range 0 .. 18446744073709551615";
	assert execConv(raiserFloat(-1.0 / 0.0), RaiserConvClass.U64).error == "value -Infinity not in range 0 .. 18446744073709551615";
	assert execConv(raiserFloat(18446744073709551616.0), RaiserConvClass.U64).error == "value 18446744073709552000 not in range 0 .. 18446744073709551615";
	assert execConv(raiserFloat(-9223372036854777856.0), RaiserConvClass.U64).error.indexOf("not in range 0 .. 18446744073709551615") >= 0;
}

test "a float in an unsigned integer's range truncates toward zero" {
	assert execConv(raiserFloat(-0.9), RaiserConvClass.U8).exitValue.intVal == 0;
	assert execConv(raiserFloat(255.9), RaiserConvClass.U8).exitValue.intVal == 255;
	assert execConv(raiserFloat(4294967295.5), RaiserConvClass.U32).exitValue.intVal == 4294967295;
	assert execConv(raiserFloat(9223372036854775808.0), RaiserConvClass.U64).exitValue.intVal == int64Bits(9223372036854775808);
	assert execConv(raiserFloat(18446744073709549568.0), RaiserConvClass.U64).exitValue.intVal == int64Bits(18446744073709549568);
	assert execConv(raiserFloat(128.75), RaiserConvClass.U8, RaiserConvClass.F32 as int32).exitValue.intVal == 128;
}

test "an integer or a float converted to char stops outside 0 .. 255, as on C and JS" {
	assert execConv(raiserInt(300), RaiserConvClass.Char, RaiserConvClass.I32 as int32).error == "value 300 not in range 0 .. 255";
	assert execConv(raiserInt(-1), RaiserConvClass.Char, RaiserConvClass.I64 as int32).error == "value -1 not in range 0 .. 255";
	assert execConv(raiserInt(int64Bits(18446744073709551615)), RaiserConvClass.Char, RaiserConvClass.U64 as int32).error == "value 18446744073709551615 not in range 0 .. 255";
	assert execConv(raiserFloat(300.7), RaiserConvClass.Char).error == "value 300.7 not in range 0 .. 255";
	assert execConv(raiserFloat(0.0 / 0.0), RaiserConvClass.Char).error == "value NaN not in range 0 .. 255";
	assert execConv(raiserInt(255), RaiserConvClass.Char, RaiserConvClass.I32 as int32).exitValue.intVal == 255;
	assert execConv(raiserFloat(65.9), RaiserConvClass.Char).exitValue.intVal == 65;
	assert execConv(raiserFloat(-0.5), RaiserConvClass.Char).exitValue.intVal == 0;
}

test "a char past 127 converted to int8 stops, as on C and JS" {
	const ch = RaiserConvClass.Char as int32;
	assert execConv(raiserInt(200), RaiserConvClass.I8, ch).error == "value 200 not in range -128 .. 127";
	assert execConv(raiserInt(127), RaiserConvClass.I8, ch).exitValue.intVal == 127;
	assert execConv(raiserInt(200), RaiserConvClass.I16, ch).exitValue.intVal == 200;
}

test "a uint64 past int64 converted to a signed integer stops, as on C" {
	const u64 = RaiserConvClass.U64 as int32;
	assert execConv(raiserInt(int64Bits(9223372036854775808)), RaiserConvClass.I64, u64).error == "value 9223372036854775808 not in range -9223372036854775808 .. 9223372036854775807";
	assert execConv(raiserInt(int64Bits(9223372036854775813)), RaiserConvClass.I32, u64).error == "value 9223372036854775813 not in range -2147483648 .. 2147483647";
	assert execConv(raiserInt(9223372036854775807), RaiserConvClass.I64, u64).exitValue.intVal == 9223372036854775807;
	assert execConv(raiserInt(int64Bits(9223372036854775813)), RaiserConvClass.U32, u64).exitValue.intVal == 5;
}

test "a float wrapped to int32 takes the bitwise operand conversion of C and JS" {
	assert execConv(raiserFloat(3000000000.7), RaiserConvClass.I32Wrap).exitValue.intVal == -1294967296;
	assert execConv(raiserFloat(2147483648.0), RaiserConvClass.I32Wrap).exitValue.intVal == -2147483648;
	assert execConv(raiserFloat(-2147483649.0), RaiserConvClass.I32Wrap).exitValue.intVal == 2147483647;
	assert execConv(raiserFloat(-0.5), RaiserConvClass.I32Wrap).exitValue.intVal == 0;
	assert execConv(raiserFloat(1e20), RaiserConvClass.I32Wrap).exitValue.intVal == 1661992960;
	assert execConv(raiserFloat(0.0 / 0.0), RaiserConvClass.I32Wrap).exitValue.intVal == 0;
	assert execConv(raiserInt(4294967297), RaiserConvClass.I32Wrap).exitValue.intVal == 1;
}

test "a float converted to its bits keeps the IEEE pattern" {
	assert execConv(raiserFloat(1.5), RaiserConvClass.F64Bits).exitValue.intVal == 4609434218613702656;
	assert execConv(raiserFloat(-1.0), RaiserConvClass.F64Bits).exitValue.intVal == -4616189618054758400;
}

test "a reference converted to its identity bits is its handle, and nil is zero" {
	assert execConv(raiserObject(7), RaiserConvClass.HandleBits).exitValue.intVal == 7;
	assert execConv(raiserArray(3), RaiserConvClass.HandleBits).exitValue.intVal == 3;
	assert execConv(raiserNil(), RaiserConvClass.HandleBits).exitValue.intVal == 0;
	assert execConv(raiserConstString("k"), RaiserConvClass.HandleBits).error.startsWith("no identity bits");
}

test "a float in a signed integer's range converts by truncation" {
	assert execConv(raiserFloat(127.9), RaiserConvClass.I8).exitValue.intVal == 127;
	assert execConv(raiserFloat(-9.5), RaiserConvClass.I64).exitValue.intVal == -9;
}

test "add: 10 + 20 = 30" { assert execBinOp(RaiserOpcode.AddI64, 10, 20).exitValue.intVal == 30; }

test "sub: 100 - 42 = 58" { assert execBinOp(RaiserOpcode.SubI64, 100, 42).exitValue.intVal == 58; }

test "mul: 6 * 7 = 42" { assert execBinOp(RaiserOpcode.MulI64, 6, 7).exitValue.intVal == 42; }

test "unsigned add, sub and mul wrap past 64 bits" {
	assert execBinOp(RaiserOpcode.MulU64, 4611686018427387904, 4).exitValue.intVal == 0;
	assert execBinOp(RaiserOpcode.MulU64, -1, 3).exitValue.intVal == -3;
	assert execBinOp(RaiserOpcode.AddU64, 4611686018427387904, 4611686018427387904).exitValue.intVal == -9223372036854775807 - 1;
	assert execBinOp(RaiserOpcode.SubU64, 0, 1).exitValue.intVal == -1;
}

function execFloatDiv(a: float64, b: float64): float64 {
	return execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABC(RaiserOpcode.DivF64, 2, 0, 1),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserFloat(a), raiserFloat(b)]
	)).exitValue.floatVal;
}

test "a float divided by zero is an infinity or NaN, as on C and JS" {
	assert execFloatDiv(1.0, 0.0) == 1.0 / 0.0;
	assert execFloatDiv(-1.0, 0.0) == -1.0 / 0.0;
	assert execFloatDiv(1.0, -0.0) == -1.0 / 0.0;
	const nan = execFloatDiv(0.0, 0.0);
	assert nan != nan;
	assert execFloatDiv(1.0, 4.0) == 0.25;
}

function execFloatNeg(a: float64): float64 {
	return execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.NegF64, 1, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserFloat(a)]
	)).exitValue.floatVal;
}

test "a negated float zero keeps its sign, as on C and JS" {
	assert 1.0 / execFloatNeg(0.0) == -1.0 / 0.0;
	assert 1.0 / execFloatNeg(-0.0) == 1.0 / 0.0;
	assert execFloatNeg(2.5) == -2.5;
}

test "div: 84 / 2 = 42" { assert execBinOp(RaiserOpcode.DivI64, 84, 2).exitValue.intVal == 42; }

test "mod: 17 % 5 = 2" { assert execBinOp(RaiserOpcode.ModI64, 17, 5).exitValue.intVal == 2; }

test "neg: -(7) = -7" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.NegI64, 1, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(7)]
	));
	assert vm.exitValue.intVal == -7;
}

function execBinOpI64(op: RaiserOpcode, a: int64, b: int64): RaiserVM {
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

function execUnary(op: RaiserOpcode, a: int64, b: int32, c: int32 = 0): RaiserVM {
	return execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(op, op == RaiserOpcode.NarrowS ? 0 : 1, op == RaiserOpcode.NarrowS ? b : 0, c),
			raiserABC(RaiserOpcode.Halt, op == RaiserOpcode.NarrowS ? 0 : 1, 0, 0),
		],
		[raiserInt(a)]
	));
}

test "int64 + - * unary minus and MIN / -1 stop on overflow and keep the boundary values" {
	const low: int64 = -9223372036854775807 - 1;
	const high: int64 = 9223372036854775807;
	assert execBinOpI64(RaiserOpcode.AddI64, high, 1).error == "over- or underflow";
	assert execBinOpI64(RaiserOpcode.AddI64, low, -1).error == "over- or underflow";
	assert execBinOpI64(RaiserOpcode.AddI64, high, low).exitValue.intVal == -1;
	assert execBinOpI64(RaiserOpcode.SubI64, low, 1).error == "over- or underflow";
	assert execBinOpI64(RaiserOpcode.SubI64, 0, low).error == "over- or underflow";
	assert execBinOpI64(RaiserOpcode.SubI64, -1, low).exitValue.intVal == high;
	assert execBinOpI64(RaiserOpcode.MulI64, 4294967296, 2147483648).error == "over- or underflow";
	assert execBinOpI64(RaiserOpcode.MulI64, -1, low).error == "over- or underflow";
	assert execBinOpI64(RaiserOpcode.MulI64, low, -1).error == "over- or underflow";
	assert execBinOpI64(RaiserOpcode.MulI64, -4294967296, 2147483648).exitValue.intVal == low;
	assert execBinOpI64(RaiserOpcode.DivI64, low, -1).error == "over- or underflow";
	assert execBinOpI64(RaiserOpcode.DivI64, high, -1).exitValue.intVal == -high;
	assert execBinOpI64(RaiserOpcode.ModI64, low, -1).exitValue.intVal == 0;
	assert execUnary(RaiserOpcode.NegI64, low, 0).error == "over- or underflow";
	assert execUnary(RaiserOpcode.NegI64, high, 0).exitValue.intVal == -high;
}

test "NarrowS stops on a value outside the signed width and keeps one inside" {
	assert execUnary(RaiserOpcode.NarrowS, 128, 8).error == "over- or underflow";
	assert execUnary(RaiserOpcode.NarrowS, -129, 8).error == "over- or underflow";
	assert execUnary(RaiserOpcode.NarrowS, -128, 8).exitValue.intVal == -128;
	assert execUnary(RaiserOpcode.NarrowS, 32767, 16).exitValue.intVal == 32767;
	assert execUnary(RaiserOpcode.NarrowS, 2147483648, 32).error == "over- or underflow";
	assert execUnary(RaiserOpcode.NarrowS, -2147483648, 32).exitValue.intVal == -2147483648;
}

test "NarrowS with C = 1 stops on a value outside the unsigned width and keeps one inside" {
	assert execUnary(RaiserOpcode.NarrowS, 256, 8, 1).error == "over- or underflow";
	assert execUnary(RaiserOpcode.NarrowS, -1, 8, 1).error == "over- or underflow";
	assert execUnary(RaiserOpcode.NarrowS, 255, 8, 1).exitValue.intVal == 255;
	assert execUnary(RaiserOpcode.NarrowS, 0, 8, 1).exitValue.intVal == 0;
}

function execIsKind(value: RaiserValue, kind: RaiserValueKind): RaiserValue {
	return execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.IsKind, 1, 0, kind as number),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[value]
	)).exitValue;
}

test "IsKind answers a boolean for the value kind named by C" {
	const hit = execIsKind(raiserConstString("a"), RaiserValueKind.String);
	assert hit.kind == RaiserValueKind.Bool;
	assert hit.intVal == 1;
	assert execIsKind(raiserConstString("a"), RaiserValueKind.Float).intVal == 0;
	assert execIsKind(raiserFloat(2.5), RaiserValueKind.Float).intVal == 1;
	assert execIsKind(raiserNil(), RaiserValueKind.Nil).intVal == 1;
	assert execIsKind(raiserInt(0), RaiserValueKind.Nil).intVal == 0;
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
	assert vm.exitValue.intVal == 20;
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
	assert vm.output == "42\n";
}

test "print reaches an installed sink as each line is produced" {
	const seen: string[] = [];
	const mod = makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Print, 0, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 0, 1),
			raiserABC(RaiserOpcode.Print, 0, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(42), raiserInt(7)]
	);
	const vm = createVM(mod, "arena");
	vm.printSink = (text: string): void => { seen.push(text); };
	execLoop(vm);
	assert seen.length == 2;
	assert seen[0] == "42";
	assert seen[1] == "7";
	assert vm.output == "42\n7\n";
}

test "print without a sink still captures output" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Print, 0, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(5)]
	));
	assert vm.printSink == null;
	assert vm.output == "5\n";
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
	assert vm.exitValue.intVal == 1;
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
	assert vm.exitValue.intVal == 0;
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
	assert vm.exitValue.intVal == 15;
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
	assert vm.exitValue.intVal == 1;
}

test "NewArray empty" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),   // R0 = []
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[]
	));
	assert vm.exitValue.kind == RaiserValueKind.Array;
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
	assert vm.exitValue.intVal == 20;
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
	assert vm.exitValue.intVal == 3;
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
	assert vm.exitValue.intVal == 1;
}

test "ArraySetLen truncates" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),   // R0 = []
			raiserABx(RaiserOpcode.LoadConst, 1, 0),     // R1 = 7
			raiserABC(RaiserOpcode.ArrayPush, 0, 1, 0),  // R0.push(7)
			raiserABC(RaiserOpcode.ArrayPush, 0, 1, 0),  // R0.push(7)
			raiserABC(RaiserOpcode.ArrayPush, 0, 1, 0),  // R0.push(7)
			raiserABx(RaiserOpcode.LoadConst, 2, 1),     // R2 = 1
			raiserABC(RaiserOpcode.ArraySetLen, 0, 2, 0), // R0.setLength(1)
			raiserABC(RaiserOpcode.ArrayLen, 3, 0, 0),   // R3 = 1
			raiserABC(RaiserOpcode.Halt, 3, 0, 0),
		],
		[raiserInt(7), raiserInt(1)]
	));
	assert vm.exitValue.intVal == 1;
}

test "ArraySetLen with C = 1 refuses a negative count" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABC(RaiserOpcode.ArraySetLen, 0, 1, 1),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(-1)]
	));
	assert vm.halted;
	assert vm.error == "value -1 not in range 0 .. 9223372036854775807";
}

test "ArraySetLen with C = 1 refuses a count past 2^32 - 1" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABC(RaiserOpcode.ArraySetLen, 0, 1, 1),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(4294967296)]
	));
	assert vm.error == "over- or underflow";
}

test "ArraySetLen with C = 1 accepts a valid count without growing" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABC(RaiserOpcode.ArraySetLen, 0, 1, 1),
			raiserABC(RaiserOpcode.ArrayLen, 2, 0, 0),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(3)]
	));
	assert vm.error == "";
	assert vm.exitValue.intVal == 0;
}

test "ArraySetLen nil-extends" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),   // R0 = []
			raiserABx(RaiserOpcode.LoadConst, 1, 0),     // R1 = 3
			raiserABC(RaiserOpcode.ArraySetLen, 0, 1, 0), // R0.setLength(3)
			raiserABC(RaiserOpcode.ArrayLen, 2, 0, 0),   // R2 = 3
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(3)]
	));
	assert vm.exitValue.intVal == 3;
	// the extended slot reads as nil
	const vm2 = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABC(RaiserOpcode.ArraySetLen, 0, 1, 0),
			raiserABx(RaiserOpcode.LoadConst, 3, 1),
			raiserABC(RaiserOpcode.LoadIndex, 4, 0, 3),
			raiserABC(RaiserOpcode.Halt, 4, 0, 0),
		],
		[raiserInt(3), raiserInt(2)]
	));
	assert vm2.exitValue.kind == RaiserValueKind.Nil;
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
	assert vm.exitValue.intVal == 99;
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
		[raiserInt(42), raiserConstString("x")]
	));
	assert vm.exitValue.intVal == 42;
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
		[raiserInt(10), raiserInt(20), raiserConstString("x"), raiserConstString("y")]
	));
	assert vm.exitValue.intVal == 20;
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
		[raiserInt(1), raiserInt(99), raiserConstString("x")]
	));
	assert vm.exitValue.intVal == 99;
}

test "ConcatStr: two strings" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "hello"
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = " world"
			raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),    // R2 = "hello world"
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserConstString("hello"), raiserConstString(" world")]
	));
	assert vmText(vm, vm.exitValue) == "hello world";
}

test "ConcatStr: int + string coercion" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "val: "
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = 42
			raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),    // R2 = "val: 42"
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserConstString("val: "), raiserInt(42)]
	));
	assert vmText(vm, vm.exitValue) == "val: 42";
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
		[raiserConstString("abc"), raiserInt(1), raiserInt(0)]
	));
	assert vm.exitValue.intVal == 1;
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
		[raiserConstString("abc"), raiserConstString("def"), raiserInt(1), raiserInt(0)]
	));
	assert vm.exitValue.intVal == 0;
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
		[raiserConstString("abc"), raiserConstString("def"), raiserInt(1), raiserInt(0)]
	));
	assert vm.exitValue.intVal == 1;
}

test "StrLen: string length" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "hello"
			raiserABC(RaiserOpcode.StrLen, 1, 0, 0),       // R1 = len("hello") = 5
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserConstString("hello")]
	));
	assert vm.exitValue.intVal == 5;
}

test "StrCharAt: get character" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "hello"
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = 1
			raiserABC(RaiserOpcode.StrCharAt, 2, 0, 1),    // R2 = "e"
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserConstString("hello"), raiserInt(1)]
	));
	assert vmText(vm, vm.exitValue) == "e";
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
		[raiserConstString("hello world"), raiserInt(0), raiserInt(5)]
	));
	assert vmText(vm, vm.exitValue) == "hello";
}

test "orc: a string op that writes its own source register reads the source first and frees what it released" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),       // R0 = "ab"
			raiserABx(RaiserOpcode.LoadConst, 1, 1),       // R1 = "cd"
			raiserABx(RaiserOpcode.LoadConst, 3, 2),       // R3 = 1
			raiserABx(RaiserOpcode.LoadConst, 4, 3),       // R4 = 3
			raiserABx(RaiserOpcode.LoadConst, 5, 4),       // R5 = 0
			raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),    // R2 = "abcd" (a run-time string)
			raiserABC(RaiserOpcode.StrSlice, 2, 2, 3),     // R2 = R2.slice(1, 3) = "bc"
			raiserABC(RaiserOpcode.ConcatStr, 2, 2, 2),    // R2 = "bcbc"
			raiserABC(RaiserOpcode.StrCharAt, 2, 2, 5),    // R2 = R2[0] = "b"
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserConstString("ab"), raiserConstString("cd"), raiserInt(1), raiserInt(3), raiserInt(0)]
	), "orc");
	assert vm.error == "";
	assert vmText(vm, vm.exitValue) == "b";
	assert heapStringLive(vm.arrayHeap) == 1;
}

test "StrLen: empty string" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.StrLen, 1, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserConstString("")]
	));
	assert vm.exitValue.intVal == 0;
}

test "a function whose code grew after creation is refused at entry" {
	const code: RaiserInstruction[] = [raiserABC(RaiserOpcode.Halt, 0, 0, 0)];
	const func = createRaiserFunction("grown", code, [], 0, 0, 2);
	func.code.push(raiserABC(RaiserOpcode.Halt, 0, 0, 0));
	let message = "";
	try {
		execModule(createRaiserModule("test", [func], 0));
	} catch (e) {
		message = (e as Error).message;
	}
	assert message.includes("function grown has 2 instructions but 1 packed words");
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
	assert vm.exitValue.intVal == 42;
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
	assert vm.exitValue.intVal == 30;
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
	assert vm.exitValue.intVal == 42;
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
	const mkConsts: RaiserValue[] = [raiserConstString("ref"), raiserConstString("get"), raiserConstString("n")];
	const mk = createRaiserFunction("mk", mkCode, mkConsts, 1, 0, 3);

	const entryCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 2, 0),          // R2 = 5
		raiserABC(RaiserOpcode.Move, 1, 2, 0),            // R1 = R2
		raiserABC(RaiserOpcode.Call, 0, 0, 1),             // R0 = mk(R1=5)
		raiserABC(RaiserOpcode.LoadField, 1, 0, 1),       // R1 = R0."n"
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	];
	const entryConsts: RaiserValue[] = [raiserInt(5), raiserConstString("n")];
	const entry = createRaiserFunction("main", entryCode, entryConsts, 0, 0, 4);

	const funcs: RaiserFunction[] = [mk, entry];
	const mod = createRaiserModule("test", funcs, 1);
	const vm = execModule(mod);
	assert vm.exitValue.intVal == 5;
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
	assert vm.loopCount == 101;
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
	assert vm.error == "";
	assert vm.loopCount == 3;
	assert vm.exitValue.intVal == 0;
}

test "every opcode reaches a branch of the dispatch" {
	for (let i: int32 = 0; i <= (RaiserOpcode.MulU64 as int32); i += 1) {
		// a constant, a global and a copy plan give CallHost, LoadGlobal, StoreGlobal and CopyValue an operand to read
		const mod = makeTestModule([raiserABC(i as RaiserOpcode, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], [raiserConstString("missingFn")]);
		mod.globalCount = 1;
		mod.functions[0].copyPlans.push({ kind: RaiserCopyKind.Preserve, names: [], children: [] });
		const vm = execModule(mod);
		assert !vm.error.startsWith("Unknown opcode"), vm.error;
	}
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
	assert vm.exitValue.intVal == 42;
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
	const consts: RaiserValue[] = [raiserConstString("echo"), raiserConstString("hello")];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error == "";
	assert vm.exitValue.kind == RaiserValueKind.String;
	assert vmText(vm, vm.exitValue) == "hello";
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
	const consts: RaiserValue[] = [raiserConstString("add"), raiserInt(10), raiserInt(32)];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error == "";
	assert vm.exitValue.intVal == 42;
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
	const consts: RaiserValue[] = [raiserConstString("seven")];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error == "";
	assert vm.exitValue.intVal == 7;
}

test "CallHost unknown name errors" {
	_resetHostRegistryForTests();
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [raiserConstString("missingFn")];
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error.length > 0;
	assert vm.halted;
}

function execHostRaiseInCatch(fatal: boolean): RaiserVM {
	registerHostFn("raise", (args: RaiserValue[]): RaiserValue => {
		raiseFromHost("host failure", fatal);
		return raiserNil();
	});
	return execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.Try, 0, 3),
			raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
			raiserAx(RaiserOpcode.Jump, 4),
			raiserABx(RaiserOpcode.Catch, 1, 4),
			raiserABx(RaiserOpcode.Try, 0, 3),
			raiserABC(RaiserOpcode.Print, 1, 0, 0),
			raiserAx(RaiserOpcode.Jump, 0),
			raiserABC(RaiserOpcode.Finally, 8, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 1),
			raiserABC(RaiserOpcode.Print, 2, 0, 0),
			raiserABC(RaiserOpcode.FinallyEnd, 8, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserConstString("raise"), raiserConstString("finally")]
	));
}

test "a fatal host error bypasses the guest catch and finally" {
	_resetHostRegistryForTests();
	const vm = execHostRaiseInCatch(true);
	assert vm.error == "host failure";
	assert vm.output == "";
	assert takeHostRaise() == null;
	assert !hostRaiseIsFatal();
}

test "a recoverable host error reaches the guest catch after a fatal host error" {
	_resetHostRegistryForTests();
	const fatal = execHostRaiseInCatch(true);
	assert fatal.error == "host failure";
	const vm = execHostRaiseInCatch(false);
	assert vm.error == "";
	assert vm.output == "host failure\nfinally\n";
	assert vmText(vm, vm.exitValue) == "host failure";
	assert vm.safePoints.length == 0;
}

test "a recoverable host error with a new message each run adds nothing to the constant table" {
	_resetHostRegistryForTests();
	const runs = [0];
	registerHostFn("raise", (args: RaiserValue[]): RaiserValue => {
		runs[0] = runs[0] + 1;
		raiseFromHost(`host failure ${runs[0]}`, false);
		return raiserNil();
	});
	const mod = makeTestModule(
		[
			raiserABx(RaiserOpcode.Try, 0, 3),
			raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
			raiserAx(RaiserOpcode.Jump, 1),
			raiserABx(RaiserOpcode.Catch, 1, 3),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserConstString("raise")]
	);
	const before = constStringCount();
	let last = "";
	for (let i = 0; i < 100000; i++) {
		const vm = execModule(mod);
		last = vmText(vm, vm.exitValue);
	}
	assert last == "host failure 100000", last;
	assert constStringCount() == before;
}

test "a host function returning a new string each run adds nothing to the constant table in either gc mode" {
	_resetHostRegistryForTests();
	const runs = [0];
	registerHostFn("mint", (args: RaiserValue[]): RaiserValue => {
		runs[0] = runs[0] + 1;
		return boxString(`minted ${runs[0]}`);
	});
	const mod = makeTestModule(
		[raiserABC(RaiserOpcode.CallHost, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
		[raiserConstString("mint")]
	);
	const before = constStringCount();
	for (const mode of ["orc", "arena"]) {
		let last = "";
		for (let i = 0; i < 50000; i++) {
			const vm = execModule(mod, mode);
			last = vmText(vm, vm.exitValue);
		}
		assert last.startsWith("minted "), last;
	}
	assert constStringCount() == before;
}

test "restricted CallHost rejects an unclassified host" {
	_resetHostRegistryForTests();
	const fn: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(1);
	registerHostFn("unsafe", fn);
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const vm = createVM(makeTestModule(code, [raiserConstString("unsafe")]));
	vm.hostCallsRestricted = true;
	vm.hostPolicySource = "/cache/evil.ms";
	execLoop(vm);
	assert vm.error.indexOf("host function 'unsafe'", 0) >= 0;
	assert vm.error.indexOf("/cache/evil.ms", 0) >= 0;
}

test "restricted CallHost allows a classified pure host" {
	_resetHostRegistryForTests();
	const fn: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(7);
	registerHostFn("pure", fn, HostCapability.Pure);
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const vm = createVM(makeTestModule(code, [raiserConstString("pure")]));
	vm.hostCallsRestricted = true;
	vm.hostPolicySource = "/cache/good.ms";
	execLoop(vm);
	assert vm.error == "";
	assert vm.exitValue.intVal == 7;
}

test "instruction line field preserved" {
	const inst = raiserABC(RaiserOpcode.AddI64, 0, 1, 2);
	assert inst.line == 0;
	inst.line = 42;
	assert inst.line == 42;
}

// --- Phase 1 Safety Tests ---

test "div by zero sets error" {
	const vm = execBinOp(RaiserOpcode.DivI64, 10, 0);
	assert vm.error == "integer division by zero";
	assert vm.halted;
}

test "mod by zero sets error" {
	const vm = execBinOp(RaiserOpcode.ModI64, 10, 0);
	assert vm.error == "integer modulo by zero";
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
		[raiserInt(-1), raiserConstString("x")]
	));
	assert vm.error.length > 0;
	assert vm.halted;
}

test "a field read through nil is a nil access, not a read of a live object" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewObject, 0, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABC(RaiserOpcode.StoreField, 0, 0, 1),
			raiserABC(RaiserOpcode.LoadNil, 2, 0, 0),
			raiserABC(RaiserOpcode.LoadField, 3, 2, 0),
			raiserABC(RaiserOpcode.Halt, 3, 0, 0),
		],
		[raiserConstString("kind"), raiserInt(7)]
	));
	assert vm.halted;
	assert vm.error == "attempt to access a nil address";
}

test "a field write through nil is a nil access" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewObject, 0, 0, 0),
			raiserABC(RaiserOpcode.LoadNil, 1, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 1),
			raiserABC(RaiserOpcode.StoreField, 1, 0, 2),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserConstString("kind"), raiserInt(7)]
	));
	assert vm.halted;
	assert vm.error == "attempt to access a nil address";
}

test "an integer is not an object handle" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewObject, 0, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABC(RaiserOpcode.LoadField, 2, 1, 0),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserConstString("kind"), raiserInt(0)]
	));
	assert vm.halted;
	assert vm.error.indexOf("expected an object", 0) >= 0;
}

test "an element read through nil is a nil access, not a read of a live array" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABC(RaiserOpcode.NewArray, 0, 1, 0),
			raiserABC(RaiserOpcode.LoadNil, 2, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 3, 1),
			raiserABC(RaiserOpcode.LoadIndex, 4, 2, 3),
			raiserABC(RaiserOpcode.Halt, 4, 0, 0),
		],
		[raiserInt(10), raiserInt(0)]
	));
	assert vm.halted;
	assert vm.error == "attempt to access a nil address";
}

test "an element write through nil is a nil access" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABC(RaiserOpcode.NewArray, 0, 1, 0),
			raiserABC(RaiserOpcode.LoadNil, 2, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 3, 1),
			raiserABC(RaiserOpcode.StoreIndex, 2, 3, 1),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(10), raiserInt(0)]
	));
	assert vm.halted;
	assert vm.error == "attempt to access a nil address";
}

test "length of nil is a nil access" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),
			raiserABC(RaiserOpcode.LoadNil, 1, 0, 0),
			raiserABC(RaiserOpcode.ArrayLen, 2, 1, 0),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(0)]
	));
	assert vm.halted;
	assert vm.error == "attempt to access a nil address";
}

test "push onto nil is a nil access" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),
			raiserABC(RaiserOpcode.LoadNil, 1, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 0),
			raiserABC(RaiserOpcode.ArrayPush, 1, 2, 0),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(5)]
	));
	assert vm.halted;
	assert vm.error == "attempt to access a nil address";
}

test "setLength on nil is a nil access" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),
			raiserABC(RaiserOpcode.LoadNil, 1, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 0),
			raiserABC(RaiserOpcode.ArraySetLen, 1, 2, 0),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(3)]
	));
	assert vm.halted;
	assert vm.error == "attempt to access a nil address";
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
	assert r.intVal == 7;
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
	assert rA.intVal == 30;
	const y1 = raiserInt(1);
	const y2 = raiserInt(2);
	const argsB: RaiserValue[] = [y1, y2];
	const rB = vmCallFunction(vm, 0, argsB);
	assert rB.intVal == 3;
}

test "vmCallFunction: a failed invocation does not return the previous heap result" {
	const successful: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.NewObject, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const failed: RaiserInstruction[] = [raiserABx(RaiserOpcode.Trap, 0, 0)];
	const empty: RaiserValue[] = [];
	const first = createRaiserFunction("first", successful, empty, 0, 0, 2);
	const second = createRaiserFunction("second", failed, [raiserConstString("failed invocation")], 0, 0, 2);
	const vm = createVM(createRaiserModule("reuse", [first, second], 0), "arena");
	const before = vmCallFunction(vm, 0, empty);
	assert before.kind == RaiserValueKind.Object;
	vm.objectHeap.objects.length = 0;
	const after = vmCallFunction(vm, 1, empty);
	assert vm.error == "failed invocation";
	assert after.kind == RaiserValueKind.Nil;
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
	assert r.intVal == 7;
}

test "vmCallFunction: a host call that runs the VM again resumes the run that made it" {
	_resetHostRegistryForTests();
	const innerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
		raiserABC(RaiserOpcode.Ret, 2, 0, 0),
	];
	const innerConsts: RaiserValue[] = [raiserInt(100)];
	const inner = createRaiserFunction("inner", innerCode, innerConsts, 1, 0, 4);
	const outerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 1, 1),
		raiserABC(RaiserOpcode.Move, 3, 0, 0),
		raiserABC(RaiserOpcode.CallHost, 2, 0, 1),
		raiserABC(RaiserOpcode.AddI64, 4, 1, 2),
		raiserABC(RaiserOpcode.Ret, 4, 0, 0),
	];
	const outerConsts: RaiserValue[] = [raiserConstString("reenter"), raiserInt(7)];
	const outer = createRaiserFunction("outer", outerCode, outerConsts, 1, 0, 8);
	const funcs: RaiserFunction[] = [inner, outer];
	const vm = createVM(createRaiserModule("t", funcs, 0), "arena");
	registerHostFn("reenter", (args: RaiserValue[]): RaiserValue => {
		const first = vmCallFunction(vm, 0, [raiserInt(args[0].intVal)]);
		const second = vmCallFunction(vm, 0, [raiserInt(args[0].intVal + 1)]);
		return raiserInt(first.intVal + second.intVal);
	});
	const r = vmCallFunction(vm, 1, [raiserInt(5)]);
	assert vm.error == "";
	assert r.intVal == 218;
	assert vm.suspendedRuns.length == 0;
	assert vm.frameFloor == 0;
}

test "vmCallFunction: a host call made two frames deep returns through the frames it left" {
	_resetHostRegistryForTests();
	const addOne = createRaiserFunction("addOne", [
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
		raiserABC(RaiserOpcode.Ret, 2, 0, 0),
	], [raiserInt(1)], 1, 0, 4);
	const addTwo = createRaiserFunction("addTwo", [
		raiserABC(RaiserOpcode.Move, 2, 0, 0),
		raiserABC(RaiserOpcode.Call, 1, 0, 1),
		raiserABC(RaiserOpcode.Move, 2, 1, 0),
		raiserABC(RaiserOpcode.Call, 1, 0, 1),
		raiserABC(RaiserOpcode.Ret, 1, 0, 0),
	], [], 1, 0, 8);
	const hosted = createRaiserFunction("hosted", [
		raiserABx(RaiserOpcode.LoadConst, 1, 1),
		raiserABC(RaiserOpcode.Move, 3, 0, 0),
		raiserABC(RaiserOpcode.CallHost, 2, 0, 1),
		raiserABC(RaiserOpcode.AddI64, 4, 1, 2),
		raiserABC(RaiserOpcode.Ret, 4, 0, 0),
	], [raiserConstString("reenter"), raiserInt(7)], 1, 0, 8);
	const top = createRaiserFunction("top", [
		raiserABC(RaiserOpcode.Move, 2, 0, 0),
		raiserABC(RaiserOpcode.Call, 1, 2, 1),
		raiserABC(RaiserOpcode.Move, 2, 1, 0),
		raiserABC(RaiserOpcode.Call, 1, 0, 1),
		raiserABC(RaiserOpcode.Ret, 1, 0, 0),
	], [], 1, 0, 8);
	const vm = createVM(createRaiserModule("t", [addOne, addTwo, hosted, top], 0), "arena");
	registerHostFn("reenter", (args: RaiserValue[]): RaiserValue => {
		const first = vmCallFunction(vm, 1, [raiserInt(args[0].intVal)]);
		const second = vmCallFunction(vm, 1, [raiserInt(args[0].intVal + 1)]);
		return raiserInt(first.intVal + second.intVal);
	});
	const r = vmCallFunction(vm, 3, [raiserInt(5)]);
	assert vm.error == "";
	assert r.intVal == 23;
	assert vm.callStack.depth == 0;
	assert vm.suspendedRuns.length == 0;
	assert vm.frameFloor == 0;
}

// --- Strand scheduling ---

test "global slots remain independent across strand heaps" {
	const main = createRaiserFunction("main", [
		raiserABC(RaiserOpcode.Yield, 0, 0, 0),
		raiserABC(RaiserOpcode.LoadGlobal, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [], 0, 0, 1);
	const worker = createRaiserFunction("worker", [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.StoreGlobal, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	], [raiserInt(9)], 0, 0, 1);
	const mod = createRaiserModule("globals", [main, worker], 0);
	mod.globalCount = 1;
	const vm = createVM(mod, "orc");
	copyValueInto(vm.globals[0], raiserInt(3));
	vmSpawnStrand(vm, 1);
	execLoop(vm);
	assert vm.error == "";
	assert vm.exitValue.intVal == 3;
	assert vm.sched.strands.items[1].globals[0].intVal == 9;
}

test "single strand: no scheduler involvement" {
	const vm = execModule(makeTestModule(
		[raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
		[raiserInt(42)]
	));
	assert vm.exitValue.intVal == 42;
	assert vm.sched.strands.items.length == 1;
	assert vm.sched.strands.items[0].status == RaiserStrandStatus.Done;
}

test "two strands interleave at Yield" {
	const mainCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserABC(RaiserOpcode.Yield, 0, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 0, 1),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const mainConsts: RaiserValue[] = [raiserInt(1), raiserInt(3)];
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserABC(RaiserOpcode.Yield, 0, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 0, 1),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserInt(2), raiserInt(4)];
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 4);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = createVM(mod, "arena");
	vmSpawnStrand(vm, 1);
	execLoop(vm);

	// Control: the same main with no strand to switch to yields to itself.
	const vmAlone = createVM(mod, "arena");
	execLoop(vmAlone);
	assert vmAlone.output == "1\n3\n";

	// The worker got a turn — it produced output the control cannot have.
	// Anchored on the completion set, not the interleave: WHERE the worker's
	// output lands stops being observable once strands run on pool workers
	// (PARALOCK Amendment J, build-order step 2).
	assert vm.output.length > vmAlone.output.length;
}

test "spawned strand finishes and hands the turn back" {
	const mainCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Yield, 0, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const mainConsts: RaiserValue[] = [raiserInt(9)];
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserInt(7)];
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 4);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = createVM(mod, "arena");
	vmSpawnStrand(vm, 1);
	execLoop(vm);
	assert vm.output.length == 4;
	assert vm.sched.strands.items[1].status == RaiserStrandStatus.Done;
	assert vm.sched.strands.items[1].result.intVal == 7;
}

test "each strand keeps its own registers" {
	// Both functions write R0; if they shared a register file the main
	// strand's value would come back as the worker's.
	const mainCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Yield, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const mainConsts: RaiserValue[] = [raiserInt(11)];
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserInt(22)];
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 4);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = createVM(mod, "arena");
	vmSpawnStrand(vm, 1);
	execLoop(vm);
	assert vm.exitValue.intVal == 11;
	assert vm.sched.strands.items[1].result.intVal == 22;
}

// --- Futures: spawn / await ---

// Builds the closure pair codegen emits for a non-capturing closure:
// { fn: funcIdx, env: -1 } in R1, using K0=funcIdx, K1="fn", K2=-1, K3="env".
function closurePairConsts(funcIdx: number): RaiserValue[] {
	return [raiserInt(funcIdx as int64), raiserConstString("fn"), raiserInt(-1), raiserConstString("env")];
}

function closurePairCode(): RaiserInstruction[] {
	return [
		raiserABC(RaiserOpcode.NewObject, 1, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 2, 0),
		raiserABC(RaiserOpcode.StoreField, 1, 1, 2),
		raiserABx(RaiserOpcode.LoadConst, 2, 2),
		raiserABC(RaiserOpcode.StoreField, 1, 3, 2),
	];
}

test "spawn returns a future the strand completes, await reads it" {
	const mainCode = closurePairCode();
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABC(RaiserOpcode.Await, 4, 3, 0));
	mainCode.push(raiserABC(RaiserOpcode.Print, 4, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 4, 0, 0));
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserInt(7)];
	const fMain = createRaiserFunction("main", mainCode, closurePairConsts(1), 0, 0, 8);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod, "arena");
	assert vm.error == "";
	assert vm.output == "7\n";
	assert vm.exitValue.intVal == 7;
	assert vm.sched.futures.items.length == 1;
	assert vm.sched.futures.items[0].finished;
}

test "a ref result crosses three heaps: producer, future, reader" {
	const mainCode = closurePairCode();
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABC(RaiserOpcode.Await, 4, 3, 0));
	mainCode.push(raiserABC(RaiserOpcode.LoadField, 5, 4, 4));
	mainCode.push(raiserABC(RaiserOpcode.Print, 5, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 5, 0, 0));
	const mainConsts = closurePairConsts(1);
	mainConsts.push(raiserConstString("v"));
	const workerCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.NewObject, 0, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 1, 1),
		raiserABC(RaiserOpcode.StoreField, 0, 0, 1),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserConstString("v"), raiserInt(42)];
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 8);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod, "arena");
	assert vm.error == "";
	// The value survives being materialized twice — out of the strand that
	// built it, then out of the future's own storage into the reader.
	assert vm.output == "42\n";
	// One object per stage: the worker built it, the future owns a copy, and
	// main holds the closure it spawned plus the copy it read back.
	assert vm.sched.strands.items[1].objectHeap.objects.length == 1;
	assert vm.sched.futures.items[0].valueObjectHeap.objects.length == 1;
	assert vm.objectHeap.objects.length == 2;
}

test "a spawned strand writes to its own copy of the captured env" {
	const mainConsts: RaiserValue[] = [raiserInt(1), raiserConstString("fn"), raiserConstString("env"), raiserConstString("n"), raiserInt(7)];
	const mainCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.NewObject, 6, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 7, 4),
		raiserABC(RaiserOpcode.StoreField, 6, 3, 7),
		raiserABC(RaiserOpcode.NewObject, 1, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 2, 0),
		raiserABC(RaiserOpcode.StoreField, 1, 1, 2),
		raiserABC(RaiserOpcode.StoreField, 1, 2, 6),
		raiserABC(RaiserOpcode.Spawn, 3, 1, 0),
		raiserABC(RaiserOpcode.Await, 4, 3, 0),
		raiserABC(RaiserOpcode.LoadField, 5, 6, 3),
		raiserABC(RaiserOpcode.Print, 5, 0, 0),
		raiserABC(RaiserOpcode.Halt, 5, 0, 0),
	];
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 1, 1),
		raiserABC(RaiserOpcode.StoreField, 0, 0, 1),
		raiserABx(RaiserOpcode.LoadConst, 2, 2),
		raiserABC(RaiserOpcode.Ret, 2, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserConstString("n"), raiserInt(99), raiserInt(0)];
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 8);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod, "arena");
	assert vm.error == "";
	// C would let the child write straight through the borrow; here the child
	// owns a copy, so the parent still reads what it stored (Amendment J).
	assert vm.output == "7\n";
	const childEnv = heapObjectGetField(vm.sched.strands.items[1].objectHeap, 0, "n");
	assert childEnv.intVal == 99;
}

test "await parks the reader until the future completes" {
	// main prints 1 before the await and 3 after; the worker prints 2. The
	// await is reached while the worker is still Ready, so 3 can only follow
	// 2 if the reader actually parked and resumed.
	const mainCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 5, 4),
		raiserABC(RaiserOpcode.Print, 5, 0, 0),
	];
	for (const inst of closurePairCode()) { mainCode.push(inst); }
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABC(RaiserOpcode.Await, 4, 3, 0));
	mainCode.push(raiserABx(RaiserOpcode.LoadConst, 5, 5));
	mainCode.push(raiserABC(RaiserOpcode.Print, 5, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 4, 0, 0));
	const mainConsts = closurePairConsts(1);
	mainConsts.push(raiserInt(1));
	mainConsts.push(raiserInt(3));
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserInt(2)];
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 8);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod, "arena");
	assert vm.error == "";
	assert vm.output == "1\n2\n3\n";
}

test "a finished future can be read again" {
	const mainCode = closurePairCode();
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABC(RaiserOpcode.Await, 4, 3, 0));
	mainCode.push(raiserABC(RaiserOpcode.Print, 4, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.Await, 5, 3, 0));
	mainCode.push(raiserABC(RaiserOpcode.Print, 5, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 5, 0, 0));
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserInt(7)];
	const fMain = createRaiserFunction("main", mainCode, closurePairConsts(1), 0, 0, 8);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod, "arena");
	assert vm.error == "";
	assert vm.output == "7\n7\n";
}

test "main ending drains the strands it left running" {
	// No await: main spawns, prints, ends. The worker still runs to
	// completion first — msDrainUntilIdle parity.
	const mainCode = closurePairCode();
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABx(RaiserOpcode.LoadConst, 4, 4));
	mainCode.push(raiserABC(RaiserOpcode.Print, 4, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 4, 0, 0));
	const mainConsts = closurePairConsts(1);
	mainConsts.push(raiserInt(1));
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserInt(2)];
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 8);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod, "arena");
	assert vm.error == "";
	assert vm.output.length == 4;
	assert vm.sched.strands.items[1].status == RaiserStrandStatus.Done;
	assert vm.exitValue.intVal == 1;
}

test "process.exit skips the drain" {
	// Same program, Halt marked abrupt (inst.b = 1) as compileExitCall emits
	// it: the worker never runs. Node parity — process.exit is abrupt.
	const mainCode = closurePairCode();
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABx(RaiserOpcode.LoadConst, 4, 4));
	mainCode.push(raiserABC(RaiserOpcode.Print, 4, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 4, 1, 0));
	const mainConsts = closurePairConsts(1);
	mainConsts.push(raiserInt(1));
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserInt(2)];
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 8);
	const fWorker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod, "arena");
	assert vm.output == "1\n";
	assert vm.sched.strands.items[1].status == RaiserStrandStatus.Ready;
}

function sleepingWorker(delayMs: int64): RaiserFunction {
	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Sleep, 1, 0, 0),
		raiserABC(RaiserOpcode.Await, 2, 1, 0),
		raiserABx(RaiserOpcode.LoadConst, 3, 1),
		raiserABC(RaiserOpcode.Print, 3, 0, 0),
		raiserABC(RaiserOpcode.Ret, 3, 0, 0),
	];
	return createRaiserFunction("worker", code, [raiserInt(delayMs), raiserInt(2)], 0, 0, 4);
}

function yieldingMain(abrupt: int32): RaiserFunction {
	const mainCode = closurePairCode();
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABC(RaiserOpcode.Yield, 0, 0, 0));
	mainCode.push(raiserABx(RaiserOpcode.LoadConst, 4, 4));
	mainCode.push(raiserABC(RaiserOpcode.Print, 4, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 4, abrupt, 0));
	const mainConsts = closurePairConsts(1);
	mainConsts.push(raiserInt(1));
	return createRaiserFunction("main", mainCode, mainConsts, 0, 0, 8);
}

test "main ending waits for a strand parked on a pending timer" {
	const funcs: RaiserFunction[] = [yieldingMain(0), sleepingWorker(20)];
	const before = msMonoTimeMs();
	const vm = execModule(createRaiserModule("t", funcs, 0), "orc");
	assert vm.error == "";
	assert vm.output == "1\n2\n";
	assert msMonoTimeMs() - before >= 20;
}

test "process.exit drops a pending timer" {
	const funcs: RaiserFunction[] = [yieldingMain(1), sleepingWorker(20)];
	const vm = execModule(createRaiserModule("t", funcs, 0), "orc");
	assert vm.error == "";
	assert vm.output == "1\n";
	assert vm.sched.timers.items.length == 1;
}

test "a strand parked on a timer is not a deadlock, one parked on a future nobody completes is" {
	const mainCode = closurePairCode();
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABC(RaiserOpcode.Await, 4, 3, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 4, 0, 0));
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Sleep, 1, 0, 0),
		raiserABC(RaiserOpcode.Await, 2, 1, 0),
		raiserABx(RaiserOpcode.LoadConst, 3, 1),
		raiserABC(RaiserOpcode.Print, 3, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 4, 2),
		raiserABC(RaiserOpcode.Await, 5, 4, 0),
		raiserABC(RaiserOpcode.Ret, 5, 0, 0),
	];
	const workerConsts: RaiserValue[] = [raiserInt(5), raiserInt(2), raiserFuture(0)];
	const funcs: RaiserFunction[] = [
		createRaiserFunction("main", mainCode, closurePairConsts(1), 0, 0, 8),
		createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 6),
	];
	const vm = execModule(createRaiserModule("t", funcs, 0), "orc");
	assert vm.output == "2\n";
	assert vm.error == "deadlock: no runnable strand";
}

// --- Exceptions ---
// Every layout below is the one codegen emits: Try points at the handler
// metadata, the normal path jumps to Finally (which pops the safepoint); with
// a finally clause the catch body runs under its own Try →Finally, without
// one it jumps past FinallyEnd because the unwinder already popped the Try.

test "throw lands in the enclosing catch, then the finally runs" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.Try, 0, 4),
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Throw, 0, 0, 0),
			raiserAx(RaiserOpcode.Jump, 4),
			raiserABx(RaiserOpcode.Catch, 1, 4),
			raiserABx(RaiserOpcode.Try, 0, 3),
			raiserABC(RaiserOpcode.Print, 1, 0, 0),
			raiserAx(RaiserOpcode.Jump, 0),
			raiserABC(RaiserOpcode.Finally, 8, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 1),
			raiserABC(RaiserOpcode.Print, 2, 0, 0),
			raiserABC(RaiserOpcode.FinallyEnd, 8, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(5), raiserInt(9)]
	));
	assert vm.error == "";
	assert vm.output == "5\n9\n";
	assert vm.exitValue.intVal == 5;
	assert vm.safePoints.length == 0;
}

test "no throw skips the catch and still runs the finally" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.Try, 0, 4),
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Print, 0, 0, 0),
			raiserAx(RaiserOpcode.Jump, 4),
			raiserABx(RaiserOpcode.Catch, 1, 4),
			raiserABx(RaiserOpcode.Try, 0, 3),
			raiserABC(RaiserOpcode.Print, 1, 0, 0),
			raiserAx(RaiserOpcode.Jump, 0),
			raiserABC(RaiserOpcode.Finally, 8, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 1),
			raiserABC(RaiserOpcode.Print, 2, 0, 0),
			raiserABC(RaiserOpcode.FinallyEnd, 8, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(7), raiserInt(9)]
	));
	assert vm.error == "";
	assert vm.output == "7\n9\n";
	assert vm.safePoints.length == 0;
}

test "an uncaught throw on the main strand is a VM error" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Throw, 0, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserConstString("boom")]
	));
	assert vm.output == "";
	assert vm.error.length > 0;
}

test "a throw unwinds out of the callee into the caller's catch" {
	const mainCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.Try, 0, 5),
		raiserABC(RaiserOpcode.Call, 1, 1, 0),
		raiserABx(RaiserOpcode.LoadConst, 3, 0),
		raiserABC(RaiserOpcode.Print, 3, 0, 0),
		raiserAx(RaiserOpcode.Jump, 3),
		raiserABx(RaiserOpcode.Catch, 2, 3),
		raiserABC(RaiserOpcode.Print, 2, 0, 0),
		raiserAx(RaiserOpcode.Jump, 2),
		raiserABC(RaiserOpcode.Finally, 6, 0, 0),
		raiserABC(RaiserOpcode.FinallyEnd, 6, 0, 0),
		raiserABC(RaiserOpcode.Halt, 2, 0, 0),
	];
	const boomCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Throw, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const fMain = createRaiserFunction("main", mainCode, [raiserInt(0)], 0, 0, 8);
	const fBoom = createRaiserFunction("boom", boomCode, [raiserInt(42)], 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fBoom];
	const vm = execModule(createRaiserModule("t", funcs, 0), "arena");
	assert vm.error == "";
	// The statement after the throwing call must not run.
	assert vm.output == "42\n";
	assert vm.exitValue.intVal == 42;
}

test "a returning callee leaves no handler behind and its frame record is reused" {
	const mainCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Call, 1, 1, 0),
		raiserABC(RaiserOpcode.Call, 1, 1, 0),
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	];
	const guardedCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.Try, 0, 3),
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
		raiserABx(RaiserOpcode.Catch, 1, 2),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
		raiserABC(RaiserOpcode.Finally, 2, 0, 0),
		raiserABC(RaiserOpcode.FinallyEnd, 2, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const fMain = createRaiserFunction("main", mainCode, [], 0, 0, 4);
	const fGuarded = createRaiserFunction("guarded", guardedCode, [raiserInt(7)], 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fGuarded];
	const vm = execModule(createRaiserModule("t", funcs, 0), "arena");
	assert vm.error == "";
	assert vm.exitValue.intVal == 7;
	assert vm.safePoints.length == 0;
	assert vm.callStack.depth == 0;
	assert vm.callStack.items.length == 1;
}

test "a finally on the way out runs before the outer catch sees the throw" {
	const mainCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.Try, 0, 5),
		raiserABC(RaiserOpcode.Call, 1, 1, 0),
		raiserABx(RaiserOpcode.LoadConst, 3, 0),
		raiserABC(RaiserOpcode.Print, 3, 0, 0),
		raiserAx(RaiserOpcode.Jump, 3),
		raiserABx(RaiserOpcode.Catch, 2, 3),
		raiserABC(RaiserOpcode.Print, 2, 0, 0),
		raiserAx(RaiserOpcode.Jump, 2),
		raiserABC(RaiserOpcode.Finally, 6, 0, 0),
		raiserABC(RaiserOpcode.FinallyEnd, 6, 0, 0),
		raiserABC(RaiserOpcode.Halt, 2, 0, 0),
	];
	// inner: try { throw 8 } finally { print 6 } — no catch, so the safepoint
	// points straight at Finally and the throw resumes after it.
	const innerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.Try, 0, 4),
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Throw, 0, 0, 0),
		raiserAx(RaiserOpcode.Jump, 0),
		raiserABC(RaiserOpcode.Finally, 2, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 1, 1),
		raiserABC(RaiserOpcode.Print, 1, 0, 0),
		raiserABC(RaiserOpcode.FinallyEnd, 2, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const fMain = createRaiserFunction("main", mainCode, [raiserInt(0)], 0, 0, 8);
	const fInner = createRaiserFunction("inner", innerCode, [raiserInt(8), raiserInt(6)], 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fInner];
	const vm = execModule(createRaiserModule("t", funcs, 0), "arena");
	assert vm.error == "";
	assert vm.output == "6\n8\n";
}

test "a throw in a spawned strand fails its future and re-raises in the reader" {
	const mainCode = closurePairCode();
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABx(RaiserOpcode.Try, 0, 5));
	mainCode.push(raiserABC(RaiserOpcode.Await, 4, 3, 0));
	mainCode.push(raiserABx(RaiserOpcode.LoadConst, 5, 4));
	mainCode.push(raiserABC(RaiserOpcode.Print, 5, 0, 0));
	mainCode.push(raiserAx(RaiserOpcode.Jump, 3));
	mainCode.push(raiserABx(RaiserOpcode.Catch, 6, 3));
	mainCode.push(raiserABC(RaiserOpcode.Print, 6, 0, 0));
	mainCode.push(raiserAx(RaiserOpcode.Jump, 2));
	mainCode.push(raiserABC(RaiserOpcode.Finally, 10, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.FinallyEnd, 10, 0, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 6, 0, 0));
	const mainConsts = closurePairConsts(1);
	mainConsts.push(raiserInt(0));
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Throw, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 12);
	const fWorker = createRaiserFunction("worker", workerCode, [raiserConstString("boom")], 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const vm = execModule(createRaiserModule("t", funcs, 0), "arena");
	assert vm.error == "";
	assert vm.output == "boom\n";
	assert vm.sched.futures.items[0].failed;
	assert vm.sched.futures.items[0].errorObserved;
	assert vmOrphanFailures(vm).length == 0;
}

test "a failed future nobody read is an orphan rejection" {
	const mainCode = closurePairCode();
	mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
	mainCode.push(raiserABC(RaiserOpcode.Halt, 3, 0, 0));
	const workerCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Throw, 0, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const fMain = createRaiserFunction("main", mainCode, closurePairConsts(1), 0, 0, 8);
	const fWorker = createRaiserFunction("worker", workerCode, [raiserConstString("dropped")], 0, 0, 4);
	const funcs: RaiserFunction[] = [fMain, fWorker];
	const vm = execModule(createRaiserModule("t", funcs, 0), "arena");
	assert vm.error == "";
	const orphans = vmOrphanFailures(vm);
	assert orphans.length == 1;
	assert orphans[0] == "dropped";
}

test "awaiting a plain value is the identity" {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Await, 1, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(5)]
	));
	assert vm.error == "";
	assert vm.exitValue.intVal == 5;
}

test "trap opcode fails the VM with its message" {
	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.Trap, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [raiserConstString("compile-time-known-bad site")];
	const f = createRaiserFunction("main", code, consts, 0, 0, 4);
	const funcs: RaiserFunction[] = [f];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod, "arena");
	assert vm.error == "compile-time-known-bad site";
	assert vm.halted;
}

test "indirect call on a non-function value fails loud" {
	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABC(RaiserOpcode.CallIndirect, 2, 1, 0),
		raiserABC(RaiserOpcode.Halt, 2, 0, 0),
	];
	const consts: RaiserValue[] = [raiserNil()];
	const f = createRaiserFunction("main", code, consts, 0, 0, 8);
	const funcs: RaiserFunction[] = [f];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod, "arena");
	assert vm.error == "indirect call target is not a function";
}

test "createVM refuses an unknown gcMode" {
	const mod = makeTestModule([raiserABC(RaiserOpcode.Halt, 0, 0, 0)], [raiserNil()]);
	let refused = "";
	try {
		createVM(mod, "bogus");
	} catch (e) {
		refused = e.message;
	}
	assert refused == "internal: unknown Raiser gcMode \"bogus\"";
}

test "a register write past the reserved file is an internal error" {
	const main = createRaiserFunction("main", [
		raiserABC(RaiserOpcode.Call, 0, 1, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserNil()], 0, 0, 8);
	const wild = createRaiserFunction("wild", [
		raiserABC(RaiserOpcode.LoadNil, 255, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	], [raiserNil()], 0, 0, 1);
	let refused = "";
	try {
		execModule(createRaiserModule("t", [main, wild], 0), "arena");
	} catch (e) {
		refused = e.message;
	}
	assert refused == "internal: register 256 is outside the reserved register file";
}

test "a runtime error after a loop reports the line of the instruction that raised it" {
	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 1, 1),
		raiserABx(RaiserOpcode.LoadConst, 2, 2),
		raiserABC(RaiserOpcode.SubI64, 1, 1, 2),
		raiserABC(RaiserOpcode.BeqI64, 1, 0, 1),
		raiserAx(RaiserOpcode.Jump, -3),
		raiserABC(RaiserOpcode.DivI64, 3, 2, 0),
		raiserABC(RaiserOpcode.Halt, 3, 0, 0),
	];
	code[3].line = 5;
	code[5].line = 6;
	code[6].line = 9;
	const vm = execModule(makeTestModule(code, [raiserInt(0), raiserInt(3), raiserInt(1)]));
	assert vm.error == "integer division by zero";
	assert vm.loopCount == 2;
	assert vmDumpStack(vm).endsWith("line 9 in test (current)");
}

test "a runtime error after a call reports the caller's line and the caller's registers" {
	const callee = createRaiserFunction("zero", [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	], [raiserInt(0)], 0, 0, 1);
	const mainCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Call, 1, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 3, 0),
		raiserABC(RaiserOpcode.DivI64, 2, 3, 1),
		raiserABC(RaiserOpcode.Halt, 2, 0, 0),
	];
	mainCode[0].line = 11;
	mainCode[2].line = 12;
	const main = createRaiserFunction("main", mainCode, [raiserInt(1)], 0, 0, 6);
	const funcs: RaiserFunction[] = [callee, main];
	const vm = execModule(createRaiserModule("test", funcs, 1));
	assert vm.error == "integer division by zero";
	assert vmDumpStack(vm).endsWith("line 12 in main (current)");
}

function execImmArith(op: RaiserOpcode, a: int64, imm: int64): RaiserVM {
	return execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(op, 2, 0, immField(imm)),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(a)]
	));
}

function immCompareTaken(op: RaiserOpcode, a: int64, imm: int64): boolean {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.LoadInt, 2, immField(1), 0),
			raiserABC(op, 0, immField(imm), 1),
			raiserABC(RaiserOpcode.LoadInt, 2, immField(0), 0),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(a)]
	));
	return vm.exitValue.intVal == 1;
}

test "LoadInt loads its immediate across the field, negatives included" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.LoadInt, 0, immField(-32768), 0),
			raiserABC(RaiserOpcode.LoadInt, 1, immField(32767), 0),
			raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(0)]
	));
	assert vm.exitValue.intVal == -1;
}

test "AddI64Imm and SubI64Imm take a negative immediate and stop on overflow as the register forms do" {
	assert execImmArith(RaiserOpcode.AddI64Imm, 5, -3).exitValue.intVal == 2;
	assert execImmArith(RaiserOpcode.SubI64Imm, 5, -3).exitValue.intVal == 8;
	assert execImmArith(RaiserOpcode.AddI64Imm, 9223372036854775807, -32768).exitValue.intVal == 9223372036854743039;
	assert execImmArith(RaiserOpcode.SubI64Imm, -9223372036854775807 - 1, -32768).exitValue.intVal == -9223372036854743040;
	assert execImmArith(RaiserOpcode.AddI64Imm, 9223372036854775807, 1).error == "over- or underflow";
	assert execImmArith(RaiserOpcode.AddI64Imm, -9223372036854775807 - 1, -1).error == "over- or underflow";
	assert execImmArith(RaiserOpcode.SubI64Imm, -9223372036854775807 - 1, 1).error == "over- or underflow";
	assert execImmArith(RaiserOpcode.SubI64Imm, 9223372036854775807, -1).error == "over- or underflow";
}

test "the immediate compare-and-skip forms compare a register with the immediate, at the field bounds too" {
	assert immCompareTaken(RaiserOpcode.BeqI64Imm, 7, 7) && !immCompareTaken(RaiserOpcode.BeqI64Imm, 7, 8);
	assert immCompareTaken(RaiserOpcode.BneI64Imm, 7, 8) && !immCompareTaken(RaiserOpcode.BneI64Imm, 7, 7);
	assert immCompareTaken(RaiserOpcode.BltI64Imm, -32769, -32768) && !immCompareTaken(RaiserOpcode.BltI64Imm, -32768, -32768);
	assert immCompareTaken(RaiserOpcode.BleI64Imm, 32767, 32767) && !immCompareTaken(RaiserOpcode.BleI64Imm, 32768, 32767);
	assert immCompareTaken(RaiserOpcode.BgtI64Imm, 32768, 32767) && !immCompareTaken(RaiserOpcode.BgtI64Imm, 32767, 32767);
	assert immCompareTaken(RaiserOpcode.BgeI64Imm, -32768, -32768) && !immCompareTaken(RaiserOpcode.BgeI64Imm, -32769, -32768);
}

function branchTaken(op: RaiserOpcode, a: int64, b: int64, immediate: boolean): boolean {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABC(RaiserOpcode.LoadInt, 2, immField(1), 0),
			raiserABC(op, 0, immediate ? immField(b) : 1, branchField(1)),
			raiserABC(RaiserOpcode.LoadInt, 2, immField(0), 0),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserInt(a), raiserInt(b)]
	));
	return vm.exitValue.intVal == 1;
}

test "the compare-and-branch forms jump over the next instruction exactly when their comparison holds" {
	const regs = [RaiserOpcode.BrEqI64, RaiserOpcode.BrNeI64, RaiserOpcode.BrLtI64, RaiserOpcode.BrLeI64, RaiserOpcode.BrGtI64, RaiserOpcode.BrGeI64];
	const imms = [RaiserOpcode.BrEqI64Imm, RaiserOpcode.BrNeI64Imm, RaiserOpcode.BrLtI64Imm, RaiserOpcode.BrLeI64Imm, RaiserOpcode.BrGtI64Imm, RaiserOpcode.BrGeI64Imm];
	const pairs = [[1, 2], [2, 2], [3, 2], [-32768, -32768], [32767, 32766]];
	for (let k = 0; k < 6; k = k + 1) {
		for (const p of pairs) {
			const a = p[0] as int64;
			const b = p[1] as int64;
			const want = match (k) {
				0 => a == b,
				1 => a != b,
				2 => a < b,
				3 => a <= b,
				4 => a > b,
				_ => a >= b,
			};
			assert branchTaken(regs[k], a, b, false) == want, `${regs[k]} ${a} ${b}`;
			assert branchTaken(imms[k], a, b, true) == want, `${imms[k]} ${a} ${b}`;
		}
	}
}

test "a compare-and-branch that jumps backward spends the loop budget and a forward one does not" {
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.LoadInt, 0, immField(0), 0),
		raiserABC(RaiserOpcode.BrEqI64Imm, 0, immField(0), branchField(-2)),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const mod = createRaiserModule("test", [createRaiserFunction("loop", code, [], 0, 0, 1)], 0);
	const vm = createVM(mod);
	vm.loopLimit = 100;
	execLoop(vm);
	assert vm.halted;
	assert vm.error.indexOf("too many iterations") >= 0;
	assert vm.loopCount == 101;
	assert branchTaken(RaiserOpcode.BrEqI64Imm, 5, 5, true);
}
