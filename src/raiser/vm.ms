import { seqSwapContents, seqPointViewInto, seqCyclic, seqUncounted, seqClass, seqLen, seqLoad, seqStore, seqPush, seqBase, seqViewOffset } from "./vmSeq";
import { cellTypeIndex, isLiveCell, VmMemory, createVmMemory, reserveSlots } from "./memory";
// Raiser VM — Bytecode executor

import {
	RaiserOpcode, RaiserInstruction, RaiserConvClass, RaiserRegClass, convClassBits, convClassSigned, convTarget, convSource, convOperand,
	raiserABC, raiserABx, raiserAx, RaiserCombine, inRefFile, regClassLetter, operandKind, OPERAND_TAGGED, OPERAND_RAW, OPERAND_BARE, operandTagged,
	packedOp, packedA, packedB, packedBx, packedBranch, immValue, immField, branchField, LAST_RAISER_OPCODE, slotArrayClass, slotArrayCyclic, slotArrayUncounted, slotArrayWidth, arrayClassSlot
} from "./bytecode";
import {
	RaiserValue, RaiserValueKind, RaiserHeapKind, kindFitsClass, readDyn, heapAllocBox, heapBoxValue, heapBoxRc, heapBoxSetRc, heapBoxSetValue, makeHandle, handleIndex, handleHeapKind, handleTag, handleKind, handleValue,
	raiserNil, raiserInt, raiserFloat, raiserBool, raiserConstString, raiserArray, raiserToString,
	RaiserArrayHeap, createArrayHeap, heapAllocArray, heapAllocArrayOf, arrayRefusal, arrayHoldsHandles, arrayHeldCount, arrayHeldAt, arrayHeldRemove, arrayHeldStore, arrayHeldInsert, arrayHeldReverse, arrayHeldSort, heapAllocView, heapArrayIsView, isSeqHandle, seqCellOf, heapArrayClass, heapArrayCyclic, heapArrayUncounted, heapArraySetFlags, heapAllocArrayLike, heapArrayRc, heapArrayGet, heapArraySet, heapArrayPush, heapArraySetLen, heapArrayLen,
	RaiserObjectHeap, RaiserObjectData, RaiserClassType, createClassType, fieldNameIs, appendField, fieldIndex, fieldValueAt, fieldStoreAt, fieldRefusal, objectFieldCount, fieldNameAt, layOutObject, slotKind, createStructHeap, heapAllocObject, raiserObject, heapObjectGetField, raiserIsInstance, RAISER_NO_CLASS, heapSeqHandles, heapObjectCellHandles,
	heapNewObjectCell, objectCellHandle, objectCellFieldValue, objectCellStoreField, OWNED_BY_RECEIVER_RC, isObjectCell, objectCellClass, heapObjectClass, heapObjectFieldIndex, heapObjectFieldValueAt, heapObjectFieldNameAt, heapObjectFieldCount, heapObjectFieldRefusal, heapObjectStoreFieldAt, heapObjectAppendField, heapObjectSetRc, heapObjectLaidCount,
	raiserFuture, raiserElemAddr, raiserFieldAddrAt, fieldAddrName, heapObjectSetField, heapAllocString, heapStringText, heapStringLive, stringHandleRc, heapBoxLive,
	rcIncref, rcDecref, rcIncrefHandle, rcDecrefHandle, rcDecIsLast, rcFreeHandle, rcCountOf, copyGraph, copyGraphWith, createCopyMap, RaiserCopyMap, raiserToBool, constStringText, constStringCount, raiserEqual, heapStringEquals, heapStringLess, heapStringLessEq, heapStringLength, heapStringByteLength, heapStringSlice, heapConcat, heapAppend, heapStringHeldOnce, heapConcatHandles, heapAppendHandle, heapHandleHeldOnce, heapHandleByteAt, heapHandleCharCodeAt, clearArrayHeap, clearObjectHeap, ORC_DEFAULT_THRESHOLD,
} from "./value";
import {
	RaiserModule, RaiserFunction,
	makeTestModule, assertPacked, getFuncConst, getFuncConstLen, getModuleFunc, createRaiserFunction, createRaiserModule,
} from "./module";
import { objectCellSlot, objectCellSetSlot } from "./objectCell";
import { orcRegisterCandidate, orcUnregister, orcCollect } from "./orc";
import { ledgerAudit } from "./ledger";
import { RaiserCopyKind, RaiserCopyPlan, copyTypedValue } from "./valueCopy";
import { parseIntStr } from "../utils/string";
import { HostCapability, HostEntry, lookupHost, hostEntryAllowedInRestrictedMode, hostEntrySpawnsChild, registerHostFn, _resetHostRegistryForTests, setActiveHostHeaps, activeHostObjectHeap, activeHostArrayHeap, setActiveProgramArgv, activeProgramArgv, takeHostRaise, hostRaiseIsFatal, raiseFromHost } from "./hostRegistry";
import { RaiserHostFn, RaiserPrintSink, boxString } from "./marshal";
import { int64Bits } from "../utils/stdBackport";

@include("runtime/promise/dispatch.h");
extern function msMonoTimeMs(): int64;
extern function msSleepMs(ms: int32): void;
extern function msFloat64Bits(d: float64): int64;
extern function msBitsFloat64(u: int64): float64;
extern function msToInt32(d: float64): int32;

// --- VM State ---

export interface RaiserRegFile {
	slots: Ptr<int64>;   // a register's number is its slot: int, bool, enum and float bits, or a heap handle (0 is nil; a Dyn slot holds a box handle)
	cap: number;         // the slots reserved; the block never moves
	owner: VmMemory;     // holds the block, so clearing a heap's memory leaves the registers alone
}

export interface RaiserCallFrame {
	funcIdx: int32;
	returnIp: int32;
	returnDest: int32;   // the caller's destination operand, tagged
	base: int32;         // the caller's frame
	spBase: int32;       // safePoints length where the callee's own handlers begin
	refTop: int32;       // one past the highest ref slot of the caller's frame and of every frame below it
}

// items[0..depth) are the live frames; a popped record stays for the next call to rewrite.
export interface RaiserCallFrames {
	items: RaiserCallFrame[];
	depth: int32;
}

// A strand is one independent line of execution: its own register file, its
// own frame stack and its own heap. The whole of it is reified data — MS-level
// calls never use the host stack (vmHandleCall pushes a frame and re-points
// funcIdx/ip/base) — so a strand suspends by copying those fields out of
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
	base: int32;
	loopCount: int64;
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
	// The VM's msFutureAddCallback for combinators: the futures of FutureCombine
	// results to step when this one settles. A result future keeps its inputs
	// and its RaiserCombine; `combine` is -1 for any other future.
	dependents: int64[];
	inputs: int64[];
	combine: int32;
	// The callbacks of `.then` registered on this future, run as strands once it settles.
	thens: RaiserThen[];
}

// One `.then` (msFutureThenEnv): the output future, the callbacks, and the heaps of the strand that
// registered it, which the callback strand shares so the captures it mutates are the ones the
// registering code reads. `arg` and `shell` are what the started strand holds until it finishes.
export interface RaiserThen {
	output: int64;
	fulfilled: RaiserValue;
	rejected: RaiserValue;
	globals: RaiserValue[];
	arrayHeap: RaiserArrayHeap;
	objectHeap: RaiserObjectHeap;
	strand: number;
	arg: RaiserValue;
	shell: int64;
}

export interface RaiserFutures {
	items: RaiserFuture[];
}

export interface RaiserTimer {
	dueMs: number;
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
	thenRuns: RaiserThen[];
	readyOrder: number[];
	idleWait: boolean;
	ticked: number[];
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
	base: int32;
	callStack: RaiserCallFrames;
	arrayHeap: RaiserArrayHeap;
	objectHeap: RaiserObjectHeap;
	loopCount: int64;    // backward jumps (loop iterations) since the last entry reset
	loopLimit: int64;    // max loop iterations before the VM refuses (reference: maxLoopIterationsVM)
	error: string;    // Non-empty when VM stopped due to error
	unsettled: boolean;   // stopped with a strand parked on a future nothing can complete (exit 13)
	comptime: boolean;
	auditLedger: boolean;
	disposing: int64[];   // the cells whose destroy routine has a live frame, innermost last
	dropped: int64[];     // last-reference cells waiting for their destroy to run once the destroys in flight have returned
	dropNest: int32;      // generic destroy walks in flight on the host stack
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
	floor: number;
	suspendedRuns: RaiserRun[];
}

interface RaiserRun {
	floor: number;
	funcIdx: int32;
	base: int32;
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
	loopCount: int64;
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

const RAISER_MIN_FRAME = 256;

// A register file holds a call depth of MAX_CALL_DEPTH frames of the widest function, twice over for a run a host bridge starts
// inside another, in one block that never moves, so a register's address stays valid.
export function createRegFile(mod: RaiserModule): RaiserRegFile {
	const owner = createVmMemory();
	let widest = RAISER_MIN_FRAME;
	for (const f of mod.functions) if (f.frameSize > widest) widest = f.frameSize;
	const cap = (MAX_CALL_DEPTH + 2) * 2 * widest;
	return { slots: reserveSlots(owner, cap as int64) as Ptr<int64>, cap, owner };
}

// Called at every function-call entry with the callee's base plus its register count.
export function ensureSlots(regs: RaiserRegFile, count: number): void {
	if (count > regs.cap) throw new Error(`internal: a frame ending at register ${count} is past the ${regs.cap} reserved`);
}

// An entry frame starts on slots an earlier run may have left words in.
function startFrame(regs: RaiserRegFile, base: number, callee: RaiserFunction): void {
	ensureSlots(regs, base + callee.frameSize);
	zeroFrame(regs.slots, base as int64, (base + callee.frameSize) as int64);
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
let vmLoopLimitDefault: int64 = DEFAULT_LOOP_LIMIT;
let vmLoopLimitChosen = false;
const NO_LOOP_LIMIT: int64 = 9223372036854775807;

export function setDefaultLoopLimit(n: number): void {
	if (n > 0) {
		vmLoopLimitDefault = n as int64;
		vmLoopLimitChosen = true;
	}
}

export function createVM(mod: RaiserModule, comptime: boolean = true): RaiserVM {
	const arrayHeap = createArrayHeap();
	const regs = createRegFile(mod);
	const nilVal = raiserNil();
	const callFrames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: callFrames, depth: 0 };
	const objectHeap = createStructHeap();
	const mainResult = raiserNil();
	const mainSafePoints: number[] = [];
	const globals: RaiserValue[] = [];
	for (let i = 0; i < mod.globalCount; i += 1) globals.push(i < mod.globalInit.length ? mod.globalInit[i] : raiserNil());
	const mainStrand: RaiserStrand = { id: 0, globals, regs, callStack, arrayHeap, objectHeap, ip: 0, funcIdx: mod.entry as int32, base: 0, loopCount: 0, status: RaiserStrandStatus.Running, result: mainResult, resultFuture: -1, safePoints: mainSafePoints, currentException: raiserNil() };
	const strandItems: RaiserStrand[] = [mainStrand];
	const strands: RaiserStrands = { items: strandItems };
	const futureItems: RaiserFuture[] = [];
	const futures: RaiserFutures = { items: futureItems };
	const timerItems: RaiserTimer[] = [];
	const timers: RaiserTimers = { items: timerItems };
	const thenRuns: RaiserThen[] = [];
	const sched: RaiserSched = { strands, futures, timers, nextStrandId: 1, modules: createModuleEval(mod), thenRuns, readyOrder: [] as number[], idleWait: false, ticked: [] as number[] };
	const safePoints: number[] = [];
	return { mod, globals, regs, ip: 0, halted: false, exitValue: nilVal, output: "", printSink: null, funcIdx: mod.entry as int32, base: 0, callStack, arrayHeap, objectHeap, loopCount: 0, loopLimit: comptime || vmLoopLimitChosen ? vmLoopLimitDefault : NO_LOOP_LIMIT, error: "", comptime, auditLedger: true, disposing: [], dropped: [], dropNest: 0, sched, current: 0, yielded: false, safePoints, currentException: raiserNil(), diagMessage: "", diagLine: 0, diagColumn: 0, diagEndLine: 0, diagEndColumn: 0, hostCallsRestricted: false, hostPolicySource: "", programArgv: null, floor: 0, suspendedRuns: [], unsettled: false };
}

// --- Register access ---

// A tagged operand is (register number << 3) | class, and the number is the slot in the frame. Word, Float and Bool
// hold a word, Ref and Dyn a handle. The typed handlers read the slots directly; every other opcode reads
// and writes through the helpers below, which turn a register into a RaiserValue and back.

const CLS_WORD: int32 = 0;
const CLS_REF: int32 = 1;
const CLS_DYN: int32 = 2;
const CLS_FLOAT: int32 = 3;
const CLS_BOOL: int32 = 4;

function slotOutside(cls: int32, idx: number): Error {
	return new Error(`internal: ${regClassLetter(cls as RaiserRegClass)} register ${idx} is outside the reserved register files`);
}

function absOf(vm: RaiserVM, t: int32): number {
	const cls = t & 7;
	return (t >> 3) + (cls == CLS_REF || cls == CLS_DYN ? vm.base : vm.base);
}

// The slot a RegAddr names, as an index into the running register file.
function regIndex(vm: RaiserVM, address: int64): number {
	const index = (address - (address & 7) - (vm.regs.slots as int64)) >> 3;
	when (mode != "danger") { if (index < 0 || (index as number) >= vm.regs.cap) throw new Error(`internal: register address ${address} is outside the running register file`); }
	return index as number;
}

function readAbs(vm: RaiserVM, cls: int32, abs: number): RaiserValue {
	if (cls == CLS_REF || cls == CLS_DYN) {
		when (mode != "danger") { if (abs >= vm.regs.cap) throw slotOutside(cls, abs); }
		return handleValue(vm.regs.slots[abs]);
	}
	when (mode != "danger") { if (abs >= vm.regs.cap) throw slotOutside(cls, abs); }
	const w = vm.regs.slots[abs];
	if (cls == CLS_WORD) return raiserInt(w);
	if (cls == CLS_FLOAT) return raiserFloat(msBitsFloat64(w));
	return raiserBool(w != 0);
}

// A register as the value in it; a Dyn register reads as its box, which getDyn looks through.
function getReg(vm: RaiserVM, t: int32): RaiserValue {
	return readAbs(vm, t & 7, absOf(vm, t));
}

function getDyn(vm: RaiserVM, t: int32): RaiserValue {
	const v = getReg(vm, t);
	return v.kind == RaiserValueKind.Box ? heapBoxValue(vm.arrayHeap, v.intVal) : v;
}

// --- Box shells: the shell around a value in a register belongs to the VM, so it is held when a register or slot
// takes it and released when it is overwritten or its frame exits; every other count is the bytecode's own ---

function isShell(h: int64): boolean {
	return handleTag(h) == (RaiserHeapKind.Box as int64);
}

function holdShell(vm: RaiserVM, h: int64): void {
	if (h != 0 && isShell(h)) rcIncrefHandle(vm.arrayHeap, vm.objectHeap, h);
}

function releaseShell(vm: RaiserVM, h: int64): void {
	if (h == 0 || !isShell(h)) return;
	if (heapBoxRc(h) <= 1) heapBoxSetValue(h, raiserNil());
	rcDecrefHandle(vm.arrayHeap, vm.objectHeap, h);
}

function innerHandle(vm: RaiserVM, h: int64): int64 {
	if (h == 0 || !isShell(h)) return h;
	const inner = heapBoxValue(vm.arrayHeap, h);
	return inner.kind == RaiserValueKind.String || inner.kind == RaiserValueKind.Array || inner.kind == RaiserValueKind.Object ? inner.intVal : 0;
}

function unshell(vm: RaiserVM, abs: int64): void {
	const h = vm.regs.slots[abs];
	if (h == 0 || !isShell(h)) return;
	if (heapBoxRc(h) <= 1) heapBoxSetValue(h, raiserNil());
}

function vmIncref(vm: RaiserVM, val: RaiserValue): void {
	if (val.kind == RaiserValueKind.Box) holdShell(vm, val.intVal);
}

function vmDecref(vm: RaiserVM, val: RaiserValue): void {
	if (val.kind == RaiserValueKind.Box) releaseShell(vm, val.intVal);
}

// The store of a handle into a Ref or Dyn slot: storing the handle a register already holds
// changes no count, and otherwise the new shell is held before the old one is released.
@inline
function writeRef(vm: RaiserVM, abs: int64, handle: int64): void {
	const old = vm.regs.slots[abs];
	if (old == handle) return;
	holdShell(vm, handle);
	vm.regs.slots[abs] = handle;
	releaseShell(vm, old);
}

// The store of a handle into a Ref slot, in the order writeRef keeps.
@inline
function storeCellRef(vm: RaiserVM, cell: int64, idx: int32, handle: int64): void {
	const old = objectCellSlot(cell, idx);
	if (old == handle) return;
	holdShell(vm, handle);
	objectCellSetSlot(cell, idx, handle);
	releaseShell(vm, old);
}

function storeSlotRef(vm: RaiserVM, obj: Cursor<RaiserObjectData>, idx: int32, handle: int64): void {
	const old = obj.slots[idx];
	if (old == handle) return;
	holdShell(vm, handle);
	obj.slots[idx] = handle;
	releaseShell(vm, old);
}

// A frame's exit releases the shells in its own ref slots, and clears the dead ref temporaries its caller keeps above the
// call window: the frame's words landed on them, and a word left in a slot would be read back as a handle.
function leaveFrame(vm: RaiserVM, base: int64, func: RaiserFunction, frame: Cursor<RaiserCallFrame>): void {
	const slots = vm.regs.slots;
	const own = func.ownRefs;
	for (let i = 0; i < own.length; i += 1) {
		const r = base + own[i];
		const h = slots[r];
		if (h != 0) {
			slots[r] = 0;
			releaseShell(vm, h);
		}
	}
	const caller = getModuleFunc(vm.mod, frame.funcIdx);
	const held = caller.ownRefs;
	if (held.length == 0) return;
	const window = (base - frame.base) as int32;
	for (let i = 0; i < func.arity; i += 1) {
		if (window + i < caller.frameSize && inRefFile(caller.regClasses[window + i]) && !inRefFile(func.regClasses[i])) slots[base + i] = 0;
	}
	const from = window + func.arity;
	const to = (base - frame.base) as int32 + func.frameSize;
	for (let i = held.length - 1; i >= 0 && held[i] >= from; i -= 1) {
		if (held[i] < to) slots[frame.base + held[i]] = 0;
	}
}

// A callee frame overlays the registers above the call window. Shells a caller's dead temporaries still
// hold there are released before the callee's words land on them, and the callee's own ref slots
// start at zero, because a caller's word left in one would be read as a handle.
function enterRefs(vm: RaiserVM, base: int64, caller: RaiserFunction, site: int32, callee: RaiserFunction): void {
	const slots = vm.regs.slots;
	const first = caller.blocks[site] as int32;
	const callerBase = base - (first as int64);
	const from = first + (caller.blocks[site + 1] as int32);
	const to = first + callee.frameSize;
	const held = caller.ownRefs;
	for (let i = held.length - 1; i >= 0 && held[i] >= from; i -= 1) {
		if (held[i] < to) {
			const r = callerBase + held[i];
			const h = slots[r];
			if (h != 0) {
				slots[r] = 0;
				releaseShell(vm, h);
			}
		}
	}
}

function zeroOwnRefs(slots: Ptr<int64>, base: int64, callee: RaiserFunction): void {
	const own = callee.ownRefs;
	for (let i = 0; i < own.length; i += 1) slots[base + own[i]] = 0;
}

@inline
function frameRefTop(vm: RaiserVM, depth: int32, base: int32, func: RaiserFunction): int32 {
	const own = func.ownRefs;
	const mine = own.length == 0 ? 0 : base + own[own.length - 1] + 1;
	const below = depth == 0 ? 0 : vm.callStack.items[depth - 1].refTop;
	return mine > below ? mine : below;
}

function enterBelow(vm: RaiserVM, callerAt: int32, base: int64, callee: RaiserFunction, frame: Cursor<RaiserCallFrame>): void {
	const caller = getModuleFunc(vm.mod, frame.funcIdx);
	const callerEnd = (frame.base as int64) + (caller.frameSize as int64);
	const end = base + (callee.frameSize as int64);
	if (end > callerEnd) overlayBelow(vm, callerAt, callerEnd, end, true);
}

function leaveBelow(vm: RaiserVM, callerAt: int32, base: int64, callee: RaiserFunction, frame: Cursor<RaiserCallFrame>): void {
	const caller = getModuleFunc(vm.mod, frame.funcIdx);
	const callerEnd = (frame.base as int64) + (caller.frameSize as int64);
	const end = base + (callee.frameSize as int64);
	if (end > callerEnd) overlayBelow(vm, callerAt, callerEnd, end, false);
}

function overlayBelow(vm: RaiserVM, callerAt: int32, from: int64, end: int64, release: boolean): void {
	const slots = vm.regs.slots;
	let lo = from;
	let k = callerAt - 1;
	while (lo < end && k >= 0 && (vm.callStack.items[k].refTop as int64) > lo) {
		const rec = vm.callStack.items[k];
		const f = getModuleFunc(vm.mod, rec.funcIdx);
		const base = rec.base as int64;
		const top = base + (f.frameSize as int64);
		const held = f.ownRefs;
		for (let i = held.length - 1; i >= 0; i -= 1) {
			const r = base + (held[i] as int64);
			if (r < lo) break;
			if (r < end && r < top) {
				const h = slots[r];
				if (h != 0) {
					slots[r] = 0;
					if (release) releaseShell(vm, h);
				}
			}
		}
		if (top > lo) lo = top;
		k -= 1;
	}
}

function zeroFrame(slots: Ptr<int64>, from: int64, end: int64): void {
	for (let z = from; z < end; z += 1) slots[z] = 0;
}

function setException(vm: RaiserVM, value: RaiserValue): void {
	vmIncref(vm, value);
	vmDecref(vm, vm.currentException);
	vm.currentException = value;
}

// Writes a plain value (or a box) into register `abs` of file `cls` in that register's class: a Dyn
// register gets a box, any other the value a box holds.
function writeAbs(vm: RaiserVM, cls: int32, abs: number, value: RaiserValue): void {
	let val = value;
	if (val.kind == RaiserValueKind.Box && cls != CLS_DYN) val = heapBoxValue(vm.arrayHeap, val.intVal);
	if (cls == CLS_DYN) {
		if (val.kind == RaiserValueKind.Nil) { writeRef(vm, abs as int64, 0); return; }
		if (val.kind == RaiserValueKind.Box) { writeRef(vm, abs as int64, val.intVal); return; }
		const box = heapAllocBox(vm.arrayHeap, val);
		heapBoxSetRc(box, 0);
		writeRef(vm, abs as int64, box);
		return;
	}
	if (cls == CLS_FLOAT && val.kind == RaiserValueKind.Int) {
		vm.regs.slots[abs] = msFloat64Bits(val.intVal as number);
		return;
	}
	when (mode != "danger") {
		if (!kindFitsClass(val.kind, cls as RaiserRegClass)) {
			const rank = abs - (cls == CLS_REF ? vm.base : vm.base);
			vmError(vm, `internal: register R${rank} of ${vm.mod.functions[vm.funcIdx].name} is ${cls as RaiserRegClass}, got ${val.kind}`);
			return;
		}
	}
	if (cls == CLS_REF) { writeRef(vm, abs as int64, val.kind == RaiserValueKind.Nil ? 0 : val.intVal); return; }
	if (cls == CLS_WORD || cls == CLS_BOOL) { vm.regs.slots[abs] = val.intVal; return; }
	vm.regs.slots[abs] = msFloat64Bits(val.floatVal);
}

function setRegConform(vm: RaiserVM, t: int32, val: RaiserValue): void {
	writeAbs(vm, t & 7, absOf(vm, t), val);
}

function setRegInt(vm: RaiserVM, t: int32, n: int64): void {
	if ((t & 7) == CLS_WORD) { vm.regs.slots[(t >> 3) + vm.base] = n; return; }
	setRegConform(vm, t, raiserInt(n));
}

function setRegFloat(vm: RaiserVM, t: int32, f: number): void {
	if ((t & 7) == CLS_FLOAT) { vm.regs.slots[(t >> 3) + vm.base] = msFloat64Bits(f); return; }
	setRegConform(vm, t, raiserFloat(f));
}

function setRegBool(vm: RaiserVM, t: int32, b: boolean): void {
	if ((t & 7) == CLS_BOOL) { vm.regs.slots[(t >> 3) + vm.base] = b ? 1 : 0; return; }
	setRegConform(vm, t, raiserBool(b));
}

function setRegNil(vm: RaiserVM, t: int32): void {
	setRegConform(vm, t, raiserNil());
}

function setRegRef(vm: RaiserVM, t: int32, kind: RaiserValueKind, handle: int64): void {
	if ((t & 7) == CLS_REF) {
		when (mode != "danger") { if (!kindFitsClass(kind, RaiserRegClass.Ref)) { setRegConform(vm, t, { kind, intVal: handle, floatVal: 0.0 }); return; } }
		writeRef(vm, (t >> 3) + vm.base, handle);
		return;
	}
	setRegConform(vm, t, { kind, intVal: handle, floatVal: 0.0 });
}

function setRegString(vm: RaiserVM, t: int32, s: string): void {
	setRegRef(vm, t, RaiserValueKind.String, heapAllocString(vm.arrayHeap, s).intVal);
}

function vmText(vm: RaiserVM, v: RaiserValue): string {
	return heapStringText(vm.arrayHeap, v);
}

// A register's value stored into a global: the global takes its own count of whatever the
// register holds and gives up the count of what it held.
function storeRegGlobal(vm: RaiserVM, t: int32, index: number): void {
	const val = getDyn(vm, t);
	vmIncref(vm, val);
	vmDecref(vm, vm.globals[index]);
	vm.globals[index] = val;
}

// --- Error helper ---

function vmError(vm: RaiserVM, msg: string): void {
	vm.error = msg;
	vm.halted = true;
}

const MAX_CALL_DEPTH = 1024;
const INT64_LOW: int64 = -9223372036854775807 - 1;
const INT64_HIGH: int64 = 9223372036854775807;

export function mulOverflowsI64(a: int64, b: int64): boolean {
	if (a == 0 || b == 0) return false;
	if (a == -1) return b == INT64_LOW;
	if (b == -1) return a == INT64_LOW;
	return int64Bits((a as uint64) * (b as uint64)) / a != b;
}
const MAX_ARRAY_COUNT = 2147483647;

// --- Execute ---

export function execModule(mod: RaiserModule, comptime: boolean = true): RaiserVM {
	const vm = createVM(mod, comptime);
	execLoop(vm);
	return vm;
}

export function vmCallFunction(vm: RaiserVM, funcIdx: number, args: RaiserValue[]): RaiserValue {
	if (funcIdx < 0 || funcIdx >= vm.mod.functions.length) {
		vmError(vm, `vmCallFunction: function index out of bounds: ${funcIdx}`);
		return raiserNil();
	}
	const callee = getModuleFunc(vm.mod, funcIdx);
	if (hasFloor(vm) && !runSuspendedAt(vm)) suspendRun(vm);
	vm.funcIdx = funcIdx as int32;
	vm.base = vm.floor as int32;
	vm.ip = 0;
	vm.halted = false;
	vm.error = "";
	vm.exitValue = raiserNil();
	vm.diagMessage = "";
	vm.loopCount = 0;
	vm.callStack.depth = 0;
	resetStrands(vm, funcIdx);
	startFrame(vm.regs, vm.base, callee);
	let i = 0;
	while (i < args.length && i < callee.regOps.length) {
		setRegConform(vm, callee.regOps[i], args[i]);
		i = i + 1;
	}
	execLoop(vm);
	return vm.exitValue;
}

function forgetHeapStrings(slots: RaiserValue[]): void {
	for (let i = 0; i < slots.length; i += 1) {
		if (slots[i].kind == RaiserValueKind.String && handleHeapKind(slots[i].intVal) == RaiserHeapKind.String) slots[i] = raiserNil();
	}
}

function forgetHeapStringRefs(refs: Ptr<int64>, count: number): void {
	for (let i = 0; i < count; i += 1) {
		if (refs[i] != 0 && handleHeapKind(refs[i]) == RaiserHeapKind.String) refs[i] = 0;
	}
}

function hasFloor(vm: RaiserVM): boolean {
	return vm.floor > 0;
}

export function vmReleaseHeaps(vm: RaiserVM): void {
	if (hasFloor(vm)) return;
	clearObjectHeap(vm.objectHeap);
	clearArrayHeap(vm.arrayHeap);
	forgetHeapStringRefs(vm.regs.slots, getModuleFunc(vm.mod, vm.mod.entry).frameSize);
	forgetHeapStrings(vm.globals);
	if (vm.currentException.kind == RaiserValueKind.String && handleHeapKind(vm.currentException.intVal) == RaiserHeapKind.String) vm.currentException = raiserNil();
}

function runSuspendedAt(vm: RaiserVM): boolean {
	const runs = vm.suspendedRuns;
	return runs.length > 0 && runs[runs.length - 1].floor == vm.floor;
}

function suspendRun(vm: RaiserVM): void {
	vm.suspendedRuns.push({
		floor: vm.floor, funcIdx: vm.funcIdx, base: vm.base, ip: vm.ip, halted: vm.halted, yielded: vm.yielded,
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
	vm.sched = { strands: { items: strandItems }, futures: { items: futureItems }, timers: { items: timerItems }, nextStrandId: 1, modules: createModuleEval(vm.mod), thenRuns: [] as RaiserThen[], readyOrder: [] as number[], idleWait: false, ticked: [] as number[] };
	vm.safePoints = [];
	vm.currentException = raiserNil();
}

function resumeRun(vm: RaiserVM, run: RaiserRun): void {
	vm.funcIdx = run.funcIdx;
	vm.base = run.base;
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
	const mainStrand: RaiserStrand = { id: 0, globals: vm.globals, regs: vm.regs, callStack: vm.callStack, arrayHeap: vm.arrayHeap, objectHeap: vm.objectHeap, ip: 0, funcIdx: entryFuncIdx as int32, base: 0, loopCount: 0, status: RaiserStrandStatus.Running, result, resultFuture: -1, safePoints: vm.safePoints, currentException: vm.currentException };
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

function futureHandleValid(vm: RaiserVM, handle: int64): boolean {
	return handleHeapKind(handle) == RaiserHeapKind.Future && handleIndex(handle) < vm.sched.futures.items.length;
}

function newFuture(vm: RaiserVM): int64 {
	const waiters: number[] = [];
	const valueArrayHeap = createArrayHeap();
	const valueObjectHeap = createStructHeap();
	const dependents: int64[] = [];
	const inputs: int64[] = [];
	const thens: RaiserThen[] = [];
	const f: RaiserFuture = { finished: false, failed: false, errorMsg: "", errorObserved: false, value: raiserNil(), error: raiserNil(), valueArrayHeap, valueObjectHeap, waiters, record: -1, dependents, inputs, combine: -1, thens };
	vm.sched.futures.items.push(f);
	return makeHandle((vm.sched.futures.items.length - 1) as int64, RaiserHeapKind.Future);
}

function futureComplete(vm: RaiserVM, handle: int64, value: RaiserValue): void {
	if (!futureHandleValid(vm, handle)) {
		vmError(vm, `future handle out of bounds: ${handle}`);
		return;
	}
	const f = vm.sched.futures.items[handleIndex(handle)];
	if (f.finished) return;
	f.finished = true;
	// Completion runs on the producing strand, whose heap dies with it — the
	// value graph moves into storage the future owns.
	const owned = copyGraphWith(vm.arrayHeap, vm.objectHeap, f.valueArrayHeap, f.valueObjectHeap, value, strandCopyMap(vm));
	rcIncref(f.valueArrayHeap, f.valueObjectHeap, owned);
	f.value = owned;
	futureSettled(vm, handle);
}

function futureSettled(vm: RaiserVM, handle: int64): void {
	const f = vm.sched.futures.items[handleIndex(handle)];
	for (const w of f.waiters) {
		const s = vm.sched.strands.items[w];
		if (s.status == RaiserStrandStatus.Blocked) {
			s.status = RaiserStrandStatus.Ready;
			vm.sched.readyOrder.push(w);
		}
	}
	f.waiters.length = 0;
	const dependents = f.dependents;
	f.dependents = [] as int64[];
	for (const d of dependents) combineStep(vm, d, handle);
	const thens = f.thens;
	f.thens = [] as RaiserThen[];
	for (const t of thens) thenFire(vm, t, handle);
}

// --- .then (runtime/promise/combinator.c msFutureThen) ---

function thenWriteArg(t: RaiserThen, regs: RaiserRegFile, tag: int32, val: RaiserValue): void {
	const cls = tag & 7;
	const at = tag >> 3;
	if (cls == CLS_REF) {
		regs.slots[at] = val.kind == RaiserValueKind.Nil ? 0 : val.intVal;
		return;
	}
	if (cls == CLS_DYN) {
		if (val.kind == RaiserValueKind.Nil) {
			regs.slots[at] = 0;
			return;
		}
		const box = heapAllocBox(t.arrayHeap, val);
		heapBoxSetRc(box, 0);
		rcIncrefHandle(t.arrayHeap, t.objectHeap, box);
		t.shell = box;
		regs.slots[at] = box;
		return;
	}
	if (cls == CLS_FLOAT) {
		regs.slots[at] = msFloat64Bits(val.kind == RaiserValueKind.Float ? val.floatVal : val.intVal as number);
		return;
	}
	regs.slots[at] = val.kind == RaiserValueKind.Float ? val.floatVal as int64 : val.intVal;
}

// A callback strand: the pair's function on the heaps of the registering strand, with the settled value
// as its first argument when the function takes one before its environment, and the output future as its result.
function thenStart(vm: RaiserVM, t: RaiserThen, closure: RaiserValue, arg: RaiserValue): void {
	if (closure.kind != RaiserValueKind.Object) {
		vmError(vm, "internal: a .then callback is not a closure pair");
		return;
	}
	const fnField = heapObjectGetField(t.arrayHeap, t.objectHeap, closure.intVal, "fn");
	const envField = heapObjectGetField(t.arrayHeap, t.objectHeap, closure.intVal, "env");
	if (fnField.kind != RaiserValueKind.Int || fnField.intVal < 0 || fnField.intVal >= vm.mod.functions.length) {
		vmError(vm, `.then: function index out of bounds: ${fnField.intVal}`);
		return;
	}
	const funcIdx = fnField.intVal as number;
	const callee = getModuleFunc(vm.mod, funcIdx);
	const regs = createRegFile(vm.mod);
	const hasEnv = envField.kind == RaiserValueKind.Object;
	const params = callee.arity - (hasEnv ? 1 : 0);
	if (params > 1) {
		vmError(vm, `internal: .then callback ${callee.name} takes ${params} parameters`);
		return;
	}
	if (params == 1) thenWriteArg(t, regs, callee.regOps[0], arg);
	if (hasEnv) {
		if (callee.arity == 0 || (callee.regOps[params] & 7) != CLS_REF) {
			vmError(vm, `internal: .then callback ${callee.name} does not take the closure environment in a ref register`);
			return;
		}
		regs.slots[callee.regOps[params] >> 3] = envField.intVal;
	}
	const frames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: frames, depth: 0 };
	const id = vm.sched.nextStrandId;
	vm.sched.nextStrandId = id + 1;
	const sp: number[] = [];
	const s: RaiserStrand = { id, globals: t.globals, regs, callStack, arrayHeap: t.arrayHeap, objectHeap: t.objectHeap, ip: 0, funcIdx: funcIdx as int32, base: 0, loopCount: 0, status: RaiserStrandStatus.Ready, result: raiserNil(), resultFuture: t.output, safePoints: sp, currentException: raiserNil() };
	vm.sched.strands.items.push(s);
	t.strand = vm.sched.strands.items.length - 1;
	vm.sched.readyOrder.push(t.strand);
	t.arg = arg;
	vm.sched.thenRuns.push(t);
}

function thenRelease(t: RaiserThen): void {
	rcDecref(t.arrayHeap, t.objectHeap, t.arg);
	if (t.shell != 0) {
		if (heapBoxRc(t.shell) <= 1) heapBoxSetValue(t.shell, raiserNil());
		rcDecrefHandle(t.arrayHeap, t.objectHeap, t.shell);
	}
	rcDecref(t.arrayHeap, t.objectHeap, t.fulfilled);
	rcDecref(t.arrayHeap, t.objectHeap, t.rejected);
}

function thenFinished(vm: RaiserVM, strand: number): boolean {
	const runs = vm.sched.thenRuns;
	for (let i = 0; i < runs.length; i += 1) {
		if (runs[i].strand != strand) continue;
		const t = runs[i];
		for (let j = i + 1; j < runs.length; j += 1) runs[j - 1] = runs[j];
		runs.shrink(runs.length - 1);
		thenRelease(t);
		return true;
	}
	return false;
}

function thenFire(vm: RaiserVM, t: RaiserThen, settled: int64): void {
	const input = vm.sched.futures.items[handleIndex(settled)];
	if (input.failed) {
		if (t.rejected.kind == RaiserValueKind.Nil) {
			futureFailFrom(vm, t.output, input);
			thenRelease(t);
			return;
		}
		const error = copyGraph(input.valueArrayHeap, input.valueObjectHeap, t.arrayHeap, t.objectHeap, input.error);
		rcIncref(t.arrayHeap, t.objectHeap, error);
		thenStart(vm, t, t.rejected, error);
		return;
	}
	if (t.fulfilled.kind == RaiserValueKind.Nil) {
		futureCompleteFrom(vm, t.output, input);
		thenRelease(t);
		return;
	}
	const value = copyGraph(input.valueArrayHeap, input.valueObjectHeap, t.arrayHeap, t.objectHeap, input.value);
	rcIncref(t.arrayHeap, t.objectHeap, value);
	thenStart(vm, t, t.fulfilled, value);
}

function vmHandleFutureThen(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const func = getModuleFunc(vm.mod, vm.funcIdx);
	const argc = func.blocks[ic + 1] as int32;
	const source = getDyn(vm, func.blocks[ic + 3] as int32);
	const handler = getDyn(vm, func.blocks[ic + 4] as int32);
	const fulfilled = ib == 1 ? raiserNil() : handler;
	const rejected = ib == 1 ? handler : argc > 2 ? getDyn(vm, func.blocks[ic + 5] as int32) : raiserNil();
	let input: int64 = source.intVal;
	if (source.kind != RaiserValueKind.Future) {
		input = newFuture(vm);
		futureComplete(vm, input, source);
	} else if (!futureHandleValid(vm, input)) {
		vmError(vm, `future handle out of bounds: ${input}`);
		return;
	}
	const output = newFuture(vm);
	const f = vm.sched.futures.items[handleIndex(input)];
	f.errorObserved = true;
	rcIncref(vm.arrayHeap, vm.objectHeap, fulfilled);
	rcIncref(vm.arrayHeap, vm.objectHeap, rejected);
	const t: RaiserThen = { output, fulfilled, rejected, globals: vm.globals, arrayHeap: vm.arrayHeap, objectHeap: vm.objectHeap, strand: -1, arg: raiserNil(), shell: 0 };
	if (f.finished) thenFire(vm, t, input);
	else f.thens.push(t);
	setRegConform(vm, ia, raiserFuture(output));
}

// --- Combinators: Promise.all, race and any (runtime/promise/combinator.c) ---

function futureCompleteFrom(vm: RaiserVM, handle: int64, source: RaiserFuture): void {
	const f = vm.sched.futures.items[handleIndex(handle)];
	f.finished = true;
	const owned = copyGraph(source.valueArrayHeap, source.valueObjectHeap, f.valueArrayHeap, f.valueObjectHeap, source.value);
	rcIncref(f.valueArrayHeap, f.valueObjectHeap, owned);
	f.value = owned;
	futureSettled(vm, handle);
}

function futureFailFrom(vm: RaiserVM, handle: int64, source: RaiserFuture): void {
	const f = vm.sched.futures.items[handleIndex(handle)];
	f.finished = true;
	f.failed = true;
	f.errorMsg = source.errorMsg;
	f.record = source.record;
	const owned = copyGraph(source.valueArrayHeap, source.valueObjectHeap, f.valueArrayHeap, f.valueObjectHeap, source.error);
	rcIncref(f.valueArrayHeap, f.valueObjectHeap, owned);
	f.error = owned;
	futureSettled(vm, handle);
}

function futureCompleteAll(vm: RaiserVM, handle: int64): void {
	const f = vm.sched.futures.items[handleIndex(handle)];
	f.finished = true;
	const arr = heapAllocArray(f.valueArrayHeap);
	for (let i = 0; i < f.inputs.length; i += 1) {
		let item = raiserNil();
		const earlier = f.inputs.indexOf(f.inputs[i]);
		if (earlier < i) {
			item = heapArrayGet(f.valueArrayHeap, arr, earlier as int64);
		} else {
			const input = vm.sched.futures.items[handleIndex(f.inputs[i])];
			item = copyGraph(input.valueArrayHeap, input.valueObjectHeap, f.valueArrayHeap, f.valueObjectHeap, input.value);
		}
		heapArrayPush(f.valueArrayHeap, arr, item);
		rcIncref(f.valueArrayHeap, f.valueObjectHeap, item);
	}
	const owned = raiserArray(arr);
	rcIncref(f.valueArrayHeap, f.valueObjectHeap, owned);
	f.value = owned;
	futureSettled(vm, handle);
}

// Every input finished, and each with the outcome `failed` names.
function combineAllSettledAs(vm: RaiserVM, f: RaiserFuture, failed: boolean): boolean {
	for (const at of f.inputs) {
		const input = vm.sched.futures.items[handleIndex(at)];
		if (!input.finished || input.failed != failed) return false;
	}
	return true;
}

function futuresAllFinished(vm: RaiserVM, f: RaiserFuture): boolean {
	for (const at of f.inputs) {
		if (!vm.sched.futures.items[handleIndex(at)].finished) return false;
	}
	return true;
}

function futureCompleteNil(vm: RaiserVM, handle: int64): void {
	vm.sched.futures.items[handleIndex(handle)].finished = true;
	futureSettled(vm, handle);
}

// One input of the combinator `handle` settled. A failed input counts as
// handled, as a future with a callback does on C, even after the result settled.
function combineStep(vm: RaiserVM, handle: int64, settled: int64): void {
	const f = vm.sched.futures.items[handleIndex(handle)];
	const input = vm.sched.futures.items[handleIndex(settled)];
	if (input.failed) input.errorObserved = true;
	if (f.finished) return;
	if (f.combine == RaiserCombine.All as int32) {
		if (input.failed) futureFailFrom(vm, handle, input);
		else if (combineAllSettledAs(vm, f, false)) futureCompleteAll(vm, handle);
	} else if (f.combine == RaiserCombine.Race as int32) {
		if (input.failed) futureFailFrom(vm, handle, input);
		else futureCompleteFrom(vm, handle, input);
	} else if (f.combine == RaiserCombine.AllSettled as int32) {
		if (futuresAllFinished(vm, f)) futureCompleteNil(vm, handle);
	} else if (f.combine == RaiserCombine.Any as int32) {
		if (!input.failed) futureCompleteFrom(vm, handle, input);
		else if (combineAllSettledAs(vm, f, true)) futureFailPrepared(vm, handle);
	} else {
		vmError(vm, `internal: FutureCombine kind ${f.combine}`);
	}
}

// Promise.any's rejection when every input rejected: the error the call site
// made, held in the result's storage until then.
function futureFailPrepared(vm: RaiserVM, handle: int64): void {
	const f = vm.sched.futures.items[handleIndex(handle)];
	f.finished = true;
	f.failed = true;
	futureSettled(vm, handle);
}

// The display of the union member `held` is when the plan marks that member refused; "" when it is allowed.
function unionConvRefusal(vm: RaiserVM, held: RaiserValue, plan: string): string {
	let i = 0;
	while (i < plan.length) {
		const semi = plan.indexOf(";", i);
		const colon = plan.indexOf(":", semi);
		const token = plan.substring(i + 1, semi);
		const length = parseIntStr(plan.substring(semi + 1, colon));
		if (unionTokenHolds(vm, held, token)) return plan.charAt(i) == "+" ? "" : plan.substring(colon + 1, colon + 1 + length);
		i = colon + 1 + length;
	}
	return held.kind.toString();
}

function discriminantHolds(vm: RaiserVM, held: RaiserValue, spec: string): boolean {
	const eq = spec.indexOf("=");
	const at = heapObjectFieldIndex(vm.objectHeap, held.intVal, spec.substring(0, eq));
	if (at < 0) return false;
	const stored = heapObjectFieldValueAt(vm.arrayHeap, vm.objectHeap, held.intVal, at as int64);
	return stored.kind == RaiserValueKind.Int && stored.intVal == parseIntStr(spec.substring(eq + 1)) as int64;
}

function unionTokenHolds(vm: RaiserVM, held: RaiserValue, token: string): boolean {
	const head = token.charAt(0);
	if (head == "n") return held.kind == RaiserValueKind.Nil;
	if (head == "b") return held.kind == RaiserValueKind.Bool;
	if (head == "u") return held.kind == RaiserValueKind.Int || held.kind == RaiserValueKind.Float;
	if (head == "s") return held.kind == RaiserValueKind.String;
	if (head == "a") return held.kind == RaiserValueKind.Array;
	if (head == "o") return held.kind == RaiserValueKind.Object;
	if (head == "d") return held.kind == RaiserValueKind.Object && discriminantHolds(vm, held, token.substring(1));
	if (head == "c") return held.kind == RaiserValueKind.Object && raiserIsInstance(heapObjectClass(vm.objectHeap, held.intVal), raiserInt(parseIntStr(token.substring(1)) as int64));
	throw new Error("internal: the union conversion plan names the kind token '" + token + "'");
}

function literalListHolds(arr: RaiserArrayHeap, list: string, held: RaiserValue): boolean {
	const text = held.kind == RaiserValueKind.String ? heapStringText(arr, held) : "";
	const num = held.kind == RaiserValueKind.Float ? held.floatVal : held.intVal as float64;
	let i = 0;
	while (i < list.length) {
		const colon = list.indexOf(":", i);
		const n = parseIntStr(list.substring(i, colon));
		const member = list.substring(colon + 1, colon + 1 + n);
		if (held.kind == RaiserValueKind.String ? member == text : member.parseFloat() == num) return true;
		i = colon + 1 + n;
	}
	return false;
}

// A plain element (an eagerly finished async call, Promise.resolve) enters as
// a future that is already complete, so every input is read the same way; one
// value named twice enters once, so its slots keep sharing it.
function vmHandleFutureCombine(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const func = getModuleFunc(vm.mod, vm.funcIdx);
	const arr = vmHeapOperand(vm, getDyn(vm, func.blocks[ic + 3] as int32), RaiserValueKind.Array, "an array of futures");
	if (arr < 0) return;
	const handle = newFuture(vm);
	const f = vm.sched.futures.items[handleIndex(handle)];
	f.combine = ib;
	if (ib == RaiserCombine.Any as int32) {
		const rejection = getDyn(vm, func.blocks[ic + 4] as int32);
		f.errorMsg = vmExceptionText(vm, rejection);
		const owned = copyGraphWith(vm.arrayHeap, vm.objectHeap, f.valueArrayHeap, f.valueObjectHeap, rejection, strandCopyMap(vm));
		rcIncref(f.valueArrayHeap, f.valueObjectHeap, owned);
		f.error = owned;
	}
	const len = heapArrayLen(vm.arrayHeap, arr);
	for (let i = 0; i < len; i += 1) {
		const item = heapArrayGet(vm.arrayHeap, arr, i);
		if (item.kind == RaiserValueKind.Future) {
			f.inputs.push(item.intVal);
			continue;
		}
		let ready: int64 = -1;
		if (item.kind == RaiserValueKind.Array || item.kind == RaiserValueKind.Object) {
			for (let j = 0; j < i; j += 1) {
				const earlier = heapArrayGet(vm.arrayHeap, arr, j);
				if (earlier.kind == item.kind && earlier.intVal == item.intVal) ready = f.inputs[j];
			}
		}
		if (ready < 0) {
			ready = newFuture(vm);
			futureComplete(vm, ready, item);
		}
		f.inputs.push(ready);
	}
	setRegConform(vm, ia, raiserFuture(handle));
	if (f.inputs.length == 0) {
		if (ib == RaiserCombine.All as int32) futureCompleteAll(vm, handle);
		else if (ib == RaiserCombine.Any as int32) futureFailPrepared(vm, handle);
		else if (ib == RaiserCombine.AllSettled as int32) futureCompleteNil(vm, handle);
		return;
	}
	for (const at of f.inputs) {
		if (!vm.sched.futures.items[handleIndex(at)].finished) vm.sched.futures.items[handleIndex(at)].dependents.push(handle);
	}
	for (const at of f.inputs) {
		if (vm.sched.futures.items[handleIndex(at)].finished) combineStep(vm, handle, at);
	}
}

// --- Timers ---

function vmArmTimer(vm: RaiserVM, delay: RaiserValue): int64 {
	let ms: int64 = 0;
	if (delay.kind == RaiserValueKind.Float && delay.floatVal > 0) ms = delay.floatVal as int64;
	if (delay.kind == RaiserValueKind.Int && delay.intVal > 0) ms = delay.intVal;
	const timer: RaiserTimer = { dueMs: performance.now() + (ms as number), future: newFuture(vm) };
	insertTimer(vm, timer);
	return timer.future;
}

function insertTimer(vm: RaiserVM, timer: RaiserTimer): void {
	const items = vm.sched.timers.items;
	items.push(timer);
	let at = items.length - 1;
	while (at > 0 && items[at - 1].dueMs > timer.dueMs) {
		items[at] = items[at - 1];
		at -= 1;
	}
	items[at] = timer;
}

function vmFireDueTimer(vm: RaiserVM): void {
	const items = vm.sched.timers.items;
	if (items.length == 0 || items[0].dueMs > performance.now()) return;
	const timer = items[0];
	for (let i = 1; i < items.length; i += 1) items[i - 1] = items[i];
	items.shrink(items.length - 1);
	futureComplete(vm, timer.future, raiserNil());
}

function vmWaitForTimer(vm: RaiserVM): void {
	const wait = vm.sched.timers.items[0].dueMs - performance.now();
	if (wait <= 0) return;
	const wholeMs = (wait as int64) + 1;
	const capped: int64 = wholeMs > 2147483647 ? 2147483647 : wholeMs;
	msSleepMs(capped as int32);
}

function vmHandleSleep(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vm.comptime) {
		vmError(vm, "sleepAsync is not available in compile-time evaluation: a timer would make its result depend on wall-clock time");
		return;
	}
	const fut = vmArmTimer(vm, getDyn(vm, ib));
	setRegConform(vm, ia, raiserFuture(fut));
}

function futureFail(vm: RaiserVM, handle: int64, message: string, thrown: RaiserValue): void {
	if (!futureHandleValid(vm, handle)) {
		vmError(vm, `future handle out of bounds: ${handle}`);
		return;
	}
	const f = vm.sched.futures.items[handleIndex(handle)];
	if (f.finished) return;
	f.finished = true;
	f.failed = true;
	f.errorMsg = message;
	const owned = copyGraphWith(vm.arrayHeap, vm.objectHeap, f.valueArrayHeap, f.valueObjectHeap, thrown, strandCopyMap(vm));
	rcIncref(f.valueArrayHeap, f.valueObjectHeap, owned);
	f.error = owned;
	futureSettled(vm, handle);
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
	const func = getModuleFunc(vm.mod, vm.funcIdx);
	const disposing = vm.callStack.items[vm.callStack.depth - 1].returnDest == DISPOSE_DEST;
	if (disposing) vm.regs.slots[vm.base] = 0;
	const depth = vm.callStack.depth - 1;
	const frame = vm.callStack.items[depth];
	leaveFrame(vm, vm.base, func, frame);
	leaveBelow(vm, depth, vm.base as int64, func, frame);
	vm.callStack.depth = depth;
	dropSafePoints(vm, frame.spBase);
	vm.funcIdx = frame.funcIdx;
	vm.ip = frame.returnIp;
	vm.base = frame.base;
	if (disposing) vmFreeCell(vm, vm.disposing.pop());
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
		thenFinished(vm, vm.current);
		s.status = RaiserStrandStatus.Done;
		vm.yielded = true;
		return;
	}
	vmError(vm, `unhandled exception: ${msg}`);
}

const FINALLY_NORMAL: int64 = 0;
const FINALLY_RAISE: int64 = 1;
const FINALLY_RETURN: int64 = 2;

function enterFinally(vm: RaiserVM, routeRank: number, heldRank: number, kind: int64, value: RaiserValue): void {
	vm.regs.slots[(vm.base + routeRank) as int64] = kind;
	const held = operandTagged(heldRank as int32, RaiserRegClass.Dyn);
	setRegConform(vm, held, value);
	if (kind != FINALLY_NORMAL) vm.safePoints.push(pendingMarker(absOf(vm, held)));
}

function pendingMarker(abs: number): number {
	return -1 - abs;
}

function dropSafePoints(vm: RaiserVM, base: number): void {
	while (vm.safePoints.length > base) {
		const top = vm.safePoints[vm.safePoints.length - 1];
		vm.safePoints.length = vm.safePoints.length - 1;
		if (top < 0) discardPendingBox(vm, (-1 - top) as int64);
	}
}

function freePendingBox(vm: RaiserVM, abs: int64): void {
	const h = vm.regs.slots[abs];
	if (h == 0) return;
	vm.regs.slots[abs] = 0;
	releaseShell(vm, h);
}

// A pending value dropped without being re-raised or returned loses the one count it held in flight.
function discardPendingBox(vm: RaiserVM, abs: int64): void {
	const inner = innerHandle(vm, vm.regs.slots[abs]);
	freePendingBox(vm, abs);
	if (inner == 0) return;
	if (rcDecIsLast(vm.arrayHeap, vm.objectHeap, inner)) vmDestroyTop(vm, inner);
	else vmRegisterCyclic(vm, inner);
	vmDrain(vm);
}

// Landing on a Catch ends the unwind; landing on a Finally runs it and comes
// back through FinallyEnd. Out of frames means nobody handled it.
function unwindStep(vm: RaiserVM): void {
	while (true) {
		while (vm.safePoints.length > safePointBase(vm)) {
			const sp = popSafePoint(vm);
			if (sp < 0) {
				discardPendingBox(vm, (-1 - sp) as int64);
				continue;
			}
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
				setRegConform(vm, packedA(meta) as int32, vm.currentException);
				vm.ip = (sp + 1) as int32;
				return;
			}
			if (packedOp(meta) == RaiserOpcode.Finally) {
				enterFinally(vm, packedA(meta), packedB(meta), FINALLY_RAISE, vm.currentException);
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
	while (vm.safePoints.length > safePointBase(vm) && vm.safePoints[vm.safePoints.length - 1] < 0) dropSafePoints(vm, vm.safePoints.length - 1);
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
	enterFinally(vm, packedA(fin), packedB(fin), FINALLY_RETURN, raiserInt((vm.ip - 1) as int64));
	return sp + 1;
}

const MACRO_ERROR_PREFIX = "__MACRO_ERROR__:";

function vmExceptionText(vm: RaiserVM, thrown: RaiserValue): string {
	if (thrown.kind != RaiserValueKind.Object) return raiserToString(vm.arrayHeap, thrown);
	if (!isObjectCell(thrown.intVal) && handleIndex(thrown.intVal) >= vm.objectHeap.objects.length) {
		vmError(vm, `object handle out of bounds: ${thrown.intVal}`);
		return "";
	}
	return raiserToString(vm.arrayHeap, heapObjectGetField(vm.arrayHeap, vm.objectHeap, thrown.intVal, "message"));
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
	let thrown = getDyn(vm, ia);
	if (vmTakeMacroError(vm, thrown)) return;
	if (thrown.kind == RaiserValueKind.String) thrown = wrapThrownString(vm, thrown);
	setException(vm, thrown);
	unwindStep(vm);
}

function wrapThrownString(vm: RaiserVM, text: RaiserValue): RaiserValue {
	const handle = heapAllocObject(vm.objectHeap);
	vm.objectHeap.objects[handleIndex(handle)].rc = 0;
	heapObjectSetField(vm.arrayHeap, vm.objectHeap, handle, "message", text);
	vmIncref(vm, text);
	return { kind: RaiserValueKind.Object, intVal: handle, floatVal: 0.0 };
}

// Re-raise a failed future in its reader — the VM's msFutureRaiseFrom.
function raiseFromFuture(vm: RaiserVM, f: RaiserFuture): void {
	f.errorObserved = true;
	if (f.record >= 0) setException(vm, moduleErrorForReader(vm, f.record));
	else if (f.error.kind == RaiserValueKind.Nil) setException(vm, heapAllocString(vm.arrayHeap, f.errorMsg));
	else {
		const copied = copyGraph(f.valueArrayHeap, f.valueObjectHeap, vm.arrayHeap, vm.objectHeap, f.error);
		rcIncref(vm.arrayHeap, vm.objectHeap, copied);
		setException(vm, copied);
	}
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
	s.base = vm.base;
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
	vm.base = s.base;
	vm.loopCount = s.loopCount;
	vm.safePoints = s.safePoints;
	vm.currentException = s.currentException;
	s.status = RaiserStrandStatus.Running;
}

// Round-robin from the strand after the current one, so a yielding strand
// hands the turn on rather than immediately reclaiming it.
function schedulePick(vm: RaiserVM): number {
	const order = vm.sched.readyOrder;
	while (order.length > 0) {
		const idx = order.shift()!;
		if (vm.sched.strands.items[idx].status == RaiserStrandStatus.Ready) return idx;
	}
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
	s.result = value;
	s.status = RaiserStrandStatus.Done;
	if (s.resultFuture >= 0) futureComplete(vm, s.resultFuture, value);
	if (thenFinished(vm, vm.current)) return true;
	if (vm.current != 0) {
		vmLedger(vm, [vm.sched.strands.items[vm.current]], [value], "strand");
	}
	return vm.current != 0;
}

// The handles the frames of a strand hold: each frame's registers below its callee's first slot, because the
// callee's frame overlaps the rest of the caller's, which is arguments already read into it.
function frameRefRoots(vm: RaiserVM, s: RaiserStrand, running: boolean, roots: RaiserValue[]): void {
	const slots = s.regs.slots;
	const frames = running ? vm.callStack : s.callStack;
	let funcIdx = running ? vm.funcIdx : s.funcIdx;
	let base = running ? vm.base : s.base;
	let depth = frames.depth;
	let limit = getModuleFunc(vm.mod, funcIdx).frameSize;
	while (true) {
		const classes = getModuleFunc(vm.mod, funcIdx).regClasses;
		for (let r = 0; r < limit && r < classes.length; r += 1) {
			if (inRefFile(classes[r]) && slots[base + r] != 0) roots.push(handleValue(slots[base + r]));
		}
		if (depth == 0) return;
		const frame = frames.items[depth - 1];
		limit = base - frame.base;
		base = frame.base;
		funcIdx = frame.funcIdx;
		depth = depth - 1;
	}
}

function vmLedger(vm: RaiserVM, held: RaiserStrand[], extra: RaiserValue[], where: string): void {
	if (vm.comptime || !vm.auditLedger || vm.error != "") return;
	vmLedgerCollect(vm);
	const roots: RaiserValue[] = [];
	roots.push(vm.currentException);
	const running = vm.sched.strands.items[vm.current];
	for (const s of held) {
		if (where != "strand" || s.status != RaiserStrandStatus.Done) frameRefRoots(vm, s, s == running, roots);
		if (s.globals != held[0].globals) for (const g of s.globals) roots.push(g);
		if (s != running) roots.push(s.currentException);
	}
	for (const g of held[0].globals) roots.push(g);
	for (const e of extra) roots.push(e);
	const verdict = ledgerAudit(vm.arrayHeap, vm.objectHeap, roots, where);
	if (verdict != "") vmError(vm, verdict);
}

function vmLedgerCollect(vm: RaiserVM): void {
	orcCollect(vm.arrayHeap, vm.objectHeap, (h: int64): void => { vm.dropped.push(h); });
	while (vm.dropped.length > 0) vmDestroyWalk(vm, vm.dropped.pop());
}

function vmProgramLedger(vm: RaiserVM): void {
	const main = vm.sched.strands.items[0];
	const ev = vm.sched.modules;
	const extra: RaiserValue[] = [];
	for (const st of ev.states) extra.push(st.error);
	for (const job of ev.pending) extra.push(job.error);
	const sharing: RaiserStrand[] = [main];
	for (const s of vm.sched.strands.items) {
		if (s != main && s.arrayHeap == main.arrayHeap) sharing.push(s);
	}
	vmLedger(vm, sharing, extra, "program");
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
	vm.exitValue = value;
	if (!abrupt && (vmHasRunnable(vm) || vm.sched.timers.items.length > 0)) {
		vm.yielded = true;
		return;
	}
	vm.halted = true;
}

function strandCopyMap(vm: RaiserVM): RaiserCopyMap {
	const map = createCopyMap();
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
		rcIncref(arrays, objects, copied);
		globals.push(copied);
	}
	return globals;
}

export function vmSpawnStrand(vm: RaiserVM, funcIdx: number): number {
	if (funcIdx < 0 || funcIdx >= vm.mod.functions.length) {
		vmError(vm, `vmSpawnStrand: function index out of bounds: ${funcIdx}`);
		return -1;
	}
	const callee = getModuleFunc(vm.mod, funcIdx as number);
	const arrayHeap = createArrayHeap();
	const regs = createRegFile(vm.mod);
	const frames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: frames, depth: 0 };
	const id = vm.sched.nextStrandId;
	vm.sched.nextStrandId = id + 1;
	const result = raiserNil();
	const sp: number[] = [];
	const objectHeap = createStructHeap();
	const globals = copyStrandGlobals(vm, arrayHeap, objectHeap, strandCopyMap(vm));
	const s: RaiserStrand = { id, globals, regs, callStack, arrayHeap, objectHeap, ip: 0, funcIdx: funcIdx as int32, base: 0, loopCount: 0, status: RaiserStrandStatus.Ready, result, resultFuture: -1, safePoints: sp, currentException: raiserNil() };
	vm.sched.strands.items.push(s);
	vm.sched.readyOrder.push(vm.sched.strands.items.length - 1);
	return id;
}

// Start a strand for a closure pair { fn, env } and hand back the future it
// completes — the VM's msSpawn. env is nil when the closure
// captures nothing; otherwise it is the callee's last argument, and `spawn`
// takes a zero-arg closure, so env is its only one.
function vmSpawnClosure(vm: RaiserVM, closure: RaiserValue): int64 {
	if (closure.kind != RaiserValueKind.Object) {
		vmError(vm, "spawn expects a closure");
		return -1;
	}
	const fnField = heapObjectGetField(vm.arrayHeap, vm.objectHeap, closure.intVal, "fn");
	const funcIdx = fnField.intVal;
	if (fnField.kind != RaiserValueKind.Int || funcIdx < 0 || funcIdx >= vm.mod.functions.length) {
		vmError(vm, `spawn: function index out of bounds: ${funcIdx}`);
		return -1;
	}
	const callee = getModuleFunc(vm.mod, funcIdx as number);
	const arrayHeap = createArrayHeap();
	const regs = createRegFile(vm.mod);
	const objectHeap = createStructHeap();
	const envField = heapObjectGetField(vm.arrayHeap, vm.objectHeap, closure.intVal, "env");
	const copyMap = strandCopyMap(vm);
	const globals = copyStrandGlobals(vm, arrayHeap, objectHeap, copyMap);
	if (envField.kind == RaiserValueKind.Object) {
		// C hands the thunk a borrow of the parent's captures and the analyzer
		// proves the parent outlives them; a handle means nothing in another
		// heap, so the capture graph crosses as a copy the child owns.
		const envSlot = copyGraphWith(vm.arrayHeap, vm.objectHeap, arrayHeap, objectHeap, envField, copyMap);
		rcIncref(arrayHeap, objectHeap, envSlot);
		if (callee.regOps.length == 0 || (callee.regOps[0] & 7) != CLS_REF) {
			vmError(vm, `spawn: ${callee.name} does not take the closure environment in a ref register`);
			return -1;
		}
		regs.slots[callee.regOps[0] >> 3] = envSlot.intVal;
	}
	const frames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: frames, depth: 0 };
	const id = vm.sched.nextStrandId;
	vm.sched.nextStrandId = id + 1;
	const fut = newFuture(vm);
	const result = raiserNil();
	const sp: number[] = [];
	const s: RaiserStrand = { id, globals, regs, callStack, arrayHeap, objectHeap, ip: 0, funcIdx: funcIdx as int32, base: 0, loopCount: 0, status: RaiserStrandStatus.Ready, result, resultFuture: fut, safePoints: sp, currentException: raiserNil() };
	vm.sched.strands.items.push(s);
	vm.sched.readyOrder.push(vm.sched.strands.items.length - 1);
	return fut;
}

// Reading a future: finished → its value, pending → park the strand on it.
// Parking rewinds to this instruction, so the resumed strand re-reads the now
// finished future and no partial-instruction state has to be saved. PARALOCK
// §6.2 needs three await lowerings on C because its async frames are
// stackless; a strand carries its whole frame stack, so one mechanism covers
// all three — and `await` works at any call depth here.
// Read out of the future's own storage and into the reader's heap. Non-destructive: the affine rules
// (R1/R2) make a second await a compile error, so there is no read-once slot to clear here.
function readSettledFuture(vm: RaiserVM, ia: int32, f: RaiserFuture): void {
	if (f.failed) {
		raiseFromFuture(vm, f);
		return;
	}
	const copy = copyGraph(f.valueArrayHeap, f.valueObjectHeap, vm.arrayHeap, vm.objectHeap, f.value);
	rcIncref(vm.arrayHeap, vm.objectHeap, copy);
	setRegConform(vm, ia, copy);
}

function vmHandleFutureRead(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const func = getModuleFunc(vm.mod, vm.funcIdx);
	const source = getDyn(vm, func.blocks[ic + 3] as int32);
	if (source.kind != RaiserValueKind.Future) {
		if (ib == 2) setRegBool(vm, ia, true);
		else if (ib == 0) setRegConform(vm, ia, source);
		return;
	}
	if (!futureHandleValid(vm, source.intVal)) {
		vmError(vm, `future handle out of bounds: ${source.intVal}`);
		return;
	}
	const f = vm.sched.futures.items[handleIndex(source.intVal)];
	if (ib == 2) {
		setRegBool(vm, ia, f.finished);
		return;
	}
	if (!f.finished) {
		vmError(vm, "internal: a settled future was read before it settled");
		return;
	}
	if (ib == 1) {
		if (f.failed) raiseFromFuture(vm, f);
		return;
	}
	readSettledFuture(vm, ia, f);
}

// An await of a settled future resumes behind the callbacks already queued (msCallSoon), so it yields once
// and runs again; true means this run yielded.
function awaitPaysTick(vm: RaiserVM): boolean {
	const paid = vm.sched.ticked.indexOf(vm.current);
	if (paid >= 0) {
		vm.sched.ticked.splice(paid, 1);
		return false;
	}
	vm.sched.ticked.push(vm.current);
	vm.ip = vm.ip - 1;
	vm.yielded = true;
	return true;
}

function vmHandleAwait(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const v = getDyn(vm, ib);
	if (v.kind != RaiserValueKind.Future) {
		if (awaitPaysTick(vm)) return;
		setRegConform(vm, ia, v);
		return;
	}
	if (!futureHandleValid(vm, v.intVal)) {
		vmError(vm, `future handle out of bounds: ${v.intVal}`);
		return;
	}
	const f = vm.sched.futures.items[handleIndex(v.intVal)];
	if (f.finished) {
		if (awaitPaysTick(vm)) return;
		readSettledFuture(vm, ia, f);
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
	vm.sched.futures.items[handleIndex(fut)].record = at;
	vm.sched.modules.pending.push({ kind: RaiserModuleJobKind.Import, record: at, future: fut, error: raiserNil() });
	if (vm.sched.modules.strand < 0) moduleArmTask(vm);
	setRegConform(vm, ia, raiserFuture(fut));
}

function moduleNewStrand(vm: RaiserVM, funcIdx: number): number {
	const main = vm.sched.strands.items[0];
	const regs = createRegFile(vm.mod);
	const frames: RaiserCallFrame[] = [];
	const callStack: RaiserCallFrames = { items: frames, depth: 0 };
	const sp: number[] = [];
	const id = vm.sched.nextStrandId;
	vm.sched.nextStrandId = id + 1;
	const s: RaiserStrand = { id, globals: main.globals, regs, callStack, arrayHeap: main.arrayHeap, objectHeap: main.objectHeap, ip: 0, funcIdx: funcIdx as int32, base: 0, loopCount: 0, status: RaiserStrandStatus.Ready, result: raiserNil(), resultFuture: -1, safePoints: sp, currentException: raiserNil() };
	vm.sched.strands.items.push(s);
	vm.sched.readyOrder.push(vm.sched.strands.items.length - 1);
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
		st.error = error;
		vmIncref(vm, error);
	}
	ev.stack.length = 0;
	ev.frames.length = 0;
}

function moduleRunBody(vm: RaiserVM, funcIdx: number): void {
	const body = getModuleFunc(vm.mod, funcIdx);
	startFrame(vm.regs, 0, body);
	vm.callStack.depth = 0;
	const sp: number[] = [];
	vm.safePoints = sp;
	vm.funcIdx = funcIdx as int32;
	vm.base = 0;
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
	ensureSlots(vm.sched.strands.items[s].regs, getModuleFunc(vm.mod, init).frameSize);
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
	const held = error;
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
	vm.sched.futures.items[handleIndex(future)].record = at;
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
	st.error = error;
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
	const copied = copyGraph(main.arrayHeap, main.objectHeap, vm.arrayHeap, vm.objectHeap, error);
	rcIncref(vm.arrayHeap, vm.objectHeap, copied);
	return copied;
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
		if (vm.halted) vmProgramLedger(vm);
	}
}

function execStrandLoop(vm: RaiserVM): void {
	while (true) {
		runStrandSlice(vm);
		if (vm.halted) return;
		if (!vm.yielded) return;
		vm.yielded = false;
		const cur = vm.sched.strands.items[vm.current];
		if (cur.status == RaiserStrandStatus.Running) {
			cur.status = RaiserStrandStatus.Ready;
			vm.sched.readyOrder.push(vm.current);
		}
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
		if (next < 0 && vm.sched.idleWait) {
			vm.sched.idleWait = false;
			vm.sched.strands.items[0].status = RaiserStrandStatus.Ready;
			vm.sched.readyOrder.push(0);
			next = schedulePick(vm);
		}
		if (next < 0) {
			// Nothing runnable — the event loop is empty and the program is
			// over. A strand still parked on a future nobody can complete ends
			// the program with exit 13, as on C and in Node.
			if (vmHasBlocked(vm)) {
				vm.unsettled = true;
				vm.exitValue = raiserInt(13);
				vm.halted = true;
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

function vmLoopLimitMessage(vm: RaiserVM): string {
	return `interpretation requires too many iterations (limit ${vm.loopLimit}); if you are sure this is not a bug in your code, raise it with --max-vm-iterations=<n>`;
}

// What the retagging in the generic path needs per operand slot: OPERAND_* kinds from the opcode's roles.
function buildOperandKinds(): int32[] {
	const table: int32[] = [];
	for (let op = 0; op <= (LAST_RAISER_OPCODE as int32); op += 1) {
		for (let slot = 0; slot < 3; slot += 1) table.push(operandKind(op as RaiserOpcode, slot as int32));
	}
	return table;
}

const OPERAND_KINDS: int32[] = buildOperandKinds();

function retag(kind: int32, raw: int32): int32 {
	return kind <= CLS_BOOL ? (raw << 3) | kind : raw;
}

function sigPrefix(sig: int64, count: int64): int64 {
	return sig < 0 ? sig : sig & (((1 as int64) << (3 * count)) - 1);
}

// The function a closure pair laid out as `fn`, `env` calls at a CallClosureTyped site, whose callee type the checker
// holds to the site's signature, so a danger build skips the checks of the pair and the signature,
// with a non-nil env written into the site's last register; -1 sends the call to vmHandleCallClosure.
function isClosurePair(classType: RaiserClassType): boolean {
	return classType.fields.length == 2 && classType.fields[0] == "fn" && classType.fields[1] == "env";
}

function closureTarget(vm: RaiserVM, func: RaiserFunction, handle: int64, rb: int32, site: int32): int64 {
	let target: int64 = 0;
	let env: int64 = 0;
	if (handleTag(handle) == (RaiserHeapKind.Seq as int64)) {
		const cell = seqCellOf(handle);
		when (mode != "danger") {
			const t = objectCellClass(handle);
			if (t.kinds.length != 2 || t.kinds[0] != RaiserRegClass.Word || t.kinds[1] != RaiserRegClass.Ref || t.fields[0] != "fn" || t.fields[1] != "env") return -1;
		}
		target = objectCellSlot(cell, 0);
		env = objectCellSlot(cell, 1);
	} else {
		if (handleTag(handle) != (RaiserHeapKind.Object as int64)) return -1;
		when (mode != "danger") { if (handleIndex(handle) >= vm.objectHeap.objects.length) return -1; }
		const obj: Cursor<RaiserObjectData> = vm.objectHeap.objects[handleIndex(handle)];
		when (mode != "danger") { if (obj.slots.length != 2 || slotKind(obj, 0) != RaiserRegClass.Word || slotKind(obj, 1) != RaiserRegClass.Ref) return -1; }
		when (mode != "danger") { if (obj.classType.fields[0] != "fn" || obj.classType.fields[1] != "env") return -1; }
		target = obj.slots[0];
		env = obj.slots[1];
	}
	when (mode != "danger") { if (target < 0 || target >= vm.mod.functions.length) return -1; }
	let argc = func.blocks[site + 1];
	let sig = func.blocks[site + 2];
	if (env == 0) {
		argc = argc - 1;
		sig = sigPrefix(sig, argc);
	}
	when (mode != "danger") {
		const callee: Cursor<RaiserFunction> = vm.mod.functions[target];
		if (sig < 0 || argc >= callee.sigs.length || callee.sigs[argc] != sig) return -1;
	}
	if (env != 0) writeRef(vm, rb + ((func.blocks[site + 2 + argc] as int32) >> 3), env);
	return target;
}

// The hot opcodes run here on the two files and the frame's bases; every other opcode takes its
// operands retagged (each register operand carries its class) into vmStepHeap or vmStepSlow.
// vm.ip, vm.funcIdx, vm.base and vm.base are written back before any call that reads
// them; between calls the running frame lives in dispatch's locals.
// Any edit to dispatch re-allocates the registers of its hot locals (slots, code, ip): one added case measured
// +1..4% on call-heavy programs, so a new opcode's fast path goes into vmStepHeap and leaves dispatch's code as it is.
function runStrandSlice(vm: RaiserVM): void {
	if (vm.halted || vm.yielded) return;
	const func = getModuleFunc(vm.mod, vm.funcIdx);
	assertPacked(func);
	dispatch(vm, func.packed, vm.regs.slots, vm.objectHeap.objects);
}

function dispatch(vm: RaiserVM, code: Span<int64>, slots: Ptr<int64>, objects: Span<RaiserObjectData>): void {
	const mod = vm.mod;
	let funcIdx = vm.funcIdx;
	let func: Cursor<RaiserFunction> = mod.functions[funcIdx];
	let ip = vm.ip;
	let fb = vm.base;
	let budget = vm.loopLimit - vm.loopCount;
	while (true) {
		@computedGoto;
		const pc = ip;
		const word = code[pc];
		ip = pc + 1;
		const op = (word & 255) as RaiserOpcode;
		let slow = false;

		switch (op) {
			case RaiserOpcode.LoadConst: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const bx = (ib * 256 + ic);
				if (bx >= getFuncConstLen(func)) {
					vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, `constant index out of bounds: ${bx}`); return;
				} else {
					const val: Cursor<RaiserValue> = func.constants[bx];
					const cls = ia & 7;
					if (cls == CLS_WORD || cls == CLS_BOOL) {
						slots[fb + (ia >> 3)] = val.intVal;
					} else if (cls == CLS_FLOAT) {
						slots[fb + (ia >> 3)] = msFloat64Bits(val.floatVal);
					} else {
						writeRef(vm, fb + (ia >> 3), val.kind == RaiserValueKind.Nil ? 0 : val.intVal);
					}
				}
				break;
			}
			case RaiserOpcode.MoveW: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				slots[fb + ia] = slots[fb + ib];
				break;
			}
			case RaiserOpcode.MoveR: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				writeRef(vm, fb + ia, slots[fb + ib]);
				break;
			}
			case RaiserOpcode.LoadNil: {
				const ia = ((word >> 8) & 65535) as int32;
				const cls = ia & 7;
				if (cls == CLS_REF || cls == CLS_DYN) {
					writeRef(vm, fb + (ia >> 3), 0);
				} else {
					vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, `internal: register R${ia >> 3} of ${func.name} is ${cls as RaiserRegClass}, got Nil`); return;
				}
				break;
			}
			case RaiserOpcode.LoadGlobal: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				vm.funcIdx = funcIdx; vm.base = fb; setRegConform(vm, ia, vm.globals[ib]);
				break;
			}
			case RaiserOpcode.StoreGlobal: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				vm.funcIdx = funcIdx; vm.base = fb; storeRegGlobal(vm, ia, ib);
				break;
			}
			case RaiserOpcode.Jump: {
				const offset = packedBranch(word);
				if (offset < 0) {
					// Loop back-edge: this is ONE iteration. Straight-line code is
					// finite by construction and recursion is bounded by
					// MAX_CALL_DEPTH, so back-edges are the only unbounded source
					// worth budgeting (reference: handleJmpBack decrements
					// loopIterations only on backward jumps).
					budget -= 1;
					if (budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
				}
				ip = ip + offset;
				break;
			}
			case RaiserOpcode.LoadInt: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				slots[fb + ia] = immValue(ib);
				break;
			}
			case RaiserOpcode.IsKind: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if ((ib & 7) == CLS_REF && ic < 64) {
					slots[fb + ia] = (handleKind(slots[fb + (ib >> 3)]) as number) == ic ? 1 : 0;
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.BTruthy: {
				const ia = ((word >> 8) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const cls = ia & 7;
				const truthy = cls == CLS_WORD || cls == CLS_BOOL ? slots[fb + (ia >> 3)] != 0 : raiserToBool(vm.arrayHeap, readAbs(vm, cls, (ia >> 3) + (cls == CLS_REF || cls == CLS_DYN ? fb : fb)));
				if (truthy) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.CallDirect: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const depth = vm.callStack.depth;
				if (depth < MAX_CALL_DEPTH) {
					const callee: Cursor<RaiserFunction> = mod.functions[ib];
					if (depth == vm.callStack.items.length) {
						vm.callStack.items.push({ funcIdx: 0, returnIp: 0, returnDest: 0, base: 0, spBase: 0, refTop: 0 });
					}
					const frame: Cursor<RaiserCallFrame> = vm.callStack.items[depth];
					frame.funcIdx = funcIdx;
					frame.returnIp = ip;
					frame.returnDest = ia;
					frame.base = fb;
					frame.spBase = vm.safePoints.length as int32;
					frame.refTop = frameRefTop(vm, depth, fb, func);
					vm.callStack.depth = depth + 1;
					fb = fb + (func.blocks[ic] as int32);
					if (fb + callee.frameSize > vm.regs.cap) ensureSlots(vm.regs, fb + callee.frameSize);
					if (func.ownRefs.length + callee.ownRefs.length != 0) enterRefs(vm, fb as int64, func, ic, callee);
					if (fb + callee.frameSize > frame.base + func.frameSize) {
						overlayBelow(vm, depth, (frame.base + func.frameSize) as int64, (fb + callee.frameSize) as int64, true);
					}
					zeroOwnRefs(slots, fb as int64, callee);
					funcIdx = ib;
					func = callee;
					code = callee.packed;
					ip = 0;
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.CallClosureTyped: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const depth = vm.callStack.depth;
				const target = depth < MAX_CALL_DEPTH ? closureTarget(vm, func, slots[fb + ib], fb, ic) : -1;
				if (target >= 0) {
					const callee: Cursor<RaiserFunction> = mod.functions[target];
					if (depth == vm.callStack.items.length) {
						vm.callStack.items.push({ funcIdx: 0, returnIp: 0, returnDest: 0, base: 0, spBase: 0, refTop: 0 });
					}
					const frame: Cursor<RaiserCallFrame> = vm.callStack.items[depth];
					frame.funcIdx = funcIdx;
					frame.returnIp = ip;
					frame.returnDest = ia;
					frame.base = fb;
					frame.spBase = vm.safePoints.length as int32;
					frame.refTop = frameRefTop(vm, depth, fb, func);
					vm.callStack.depth = depth + 1;
					fb = fb + (func.blocks[ic] as int32);
					if (fb + callee.frameSize > vm.regs.cap) ensureSlots(vm.regs, fb + callee.frameSize);
					if (func.ownRefs.length + callee.ownRefs.length != 0) enterRefs(vm, fb as int64, func, ic, callee);
					if (fb + callee.frameSize > frame.base + func.frameSize) {
						overlayBelow(vm, depth, (frame.base + func.frameSize) as int64, (fb + callee.frameSize) as int64, true);
					}
					zeroOwnRefs(slots, fb as int64, callee);
					funcIdx = target as int32;
					func = callee;
					code = callee.packed;
					ip = 0;
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.Call: case RaiserOpcode.CallIndirect: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const target = op == RaiserOpcode.CallIndirect ? slots[fb + ib] : ib;
				const depth = vm.callStack.depth;
				let ok = depth < MAX_CALL_DEPTH;
				let callee: Cursor<RaiserFunction> = func;
				if (target >= 0 && target < mod.functions.length) {
					callee = mod.functions[target];
					const argc = func.blocks[ic + 1];
					const sig = func.blocks[ic + 2];
					ok = ok && sig >= 0 && argc < callee.sigs.length && callee.sigs[argc] == sig;
				} else {
					ok = false;
				}
				if (ok) {
					if (depth == vm.callStack.items.length) {
						vm.callStack.items.push({ funcIdx: 0, returnIp: 0, returnDest: 0, base: 0, spBase: 0, refTop: 0 });
					}
					const frame: Cursor<RaiserCallFrame> = vm.callStack.items[depth];
					frame.funcIdx = funcIdx;
					frame.returnIp = ip;
					frame.returnDest = ia;
					frame.base = fb;
					frame.spBase = vm.safePoints.length as int32;
					frame.refTop = frameRefTop(vm, depth, fb, func);
					vm.callStack.depth = depth + 1;
					fb = fb + (func.blocks[ic] as int32);
					if (fb + callee.frameSize > vm.regs.cap) ensureSlots(vm.regs, fb + callee.frameSize);
					if (func.ownRefs.length + callee.ownRefs.length != 0) enterRefs(vm, fb as int64, func, ic, callee);
					if (fb + callee.frameSize > frame.base + func.frameSize) {
						overlayBelow(vm, depth, (frame.base + func.frameSize) as int64, (fb + callee.frameSize) as int64, true);
					}
					zeroOwnRefs(slots, fb as int64, callee);
					funcIdx = target as int32;
					func = callee;
					code = callee.packed;
					if (code.length != func.code.length) assertPacked(func);
					ip = 0;
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.Ret: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const depth = vm.callStack.depth;
				if (depth > 0 && ((ic & 1) == 0 || vm.safePoints.length == vm.callStack.items[depth - 1].spBase)) {
					const frame: Cursor<RaiserCallFrame> = vm.callStack.items[depth - 1];
					const dest = frame.returnDest;
					const cls = ia & 7;
					if (cls == (dest & 7)) {
						if (cls == CLS_REF || cls == CLS_DYN) {
							const handle = slots[fb + (ia >> 3)];
							if ((ia >> 3) >= ib) {
								slots[fb + (ia >> 3)] = 0;
								const old = slots[frame.base + (dest >> 3)];
								slots[frame.base + (dest >> 3)] = handle;
								releaseShell(vm, old);
							} else {
								writeRef(vm, frame.base + (dest >> 3), handle);
							}
						} else {
							slots[frame.base + (dest >> 3)] = slots[fb + (ia >> 3)];
						}
						const caller: Cursor<RaiserFunction> = mod.functions[frame.funcIdx];
						if (func.ownRefs.length + caller.ownRefs.length != 0) leaveFrame(vm, fb, func, frame);
						if (fb + func.frameSize > frame.base + caller.frameSize) {
							overlayBelow(vm, depth - 1, (frame.base + caller.frameSize) as int64, (fb + func.frameSize) as int64, false);
						}
						vm.callStack.depth = depth - 1;
						fb = frame.base;
						funcIdx = frame.funcIdx;
						func = caller;
						code = func.packed;
						ip = frame.returnIp;
					} else {
						slow = true;
					}
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.BrEqI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] == slots[fb + ib]) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrNeI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] != slots[fb + ib]) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrLtI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] < slots[fb + ib]) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrLeI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] <= slots[fb + ib]) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrGtI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] > slots[fb + ib]) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrGeI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] >= slots[fb + ib]) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrEqI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] == immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrNeI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] != immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrLtI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] < immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrLeI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] <= immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrGtI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] > immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrGeI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] >= immValue(ib)) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrEqR: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] == slots[fb + ib]) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.BrNeR: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				if (slots[fb + ia] != slots[fb + ib]) {
					const offset = packedBranch(word);
					if (offset < 0 && --budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
					ip = ip + offset;
				}
				break;
			}
			case RaiserOpcode.ForLtI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const lhs = slots[fb + ia];
				if (lhs == INT64_HIGH) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return; }
				slots[fb + ia] = lhs + 1;
				budget -= 1;
				if (budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
				if (lhs + 1 < slots[fb + ib]) ip = ip + packedBranch(word);
				break;
			}
			case RaiserOpcode.ForLtI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const lhs = slots[fb + ia];
				if (lhs == INT64_HIGH) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return; }
				slots[fb + ia] = lhs + 1;
				budget -= 1;
				if (budget < 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, vmLoopLimitMessage(vm)); return; }
				if (lhs + 1 < immValue(ib)) ip = ip + packedBranch(word);
				break;
			}
			case RaiserOpcode.BeqR: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] == slots[fb + ib]) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BneR: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] != slots[fb + ib]) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BeqI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] == slots[fb + ib]) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BneI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] != slots[fb + ib]) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BltI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] < slots[fb + ib]) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BleI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] <= slots[fb + ib]) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BgtI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] > slots[fb + ib]) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BgeI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] >= slots[fb + ib]) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BeqI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] == immValue(ib)) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BneI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] != immValue(ib)) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BltI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] < immValue(ib)) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BleI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] <= immValue(ib)) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BgtI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] > immValue(ib)) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BgeI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ia] >= immValue(ib)) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BeqF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (msBitsFloat64(slots[fb + ia]) == msBitsFloat64(slots[fb + ib])) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BneF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (msBitsFloat64(slots[fb + ia]) != msBitsFloat64(slots[fb + ib])) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BltF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (msBitsFloat64(slots[fb + ia]) < msBitsFloat64(slots[fb + ib])) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BleF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (msBitsFloat64(slots[fb + ia]) <= msBitsFloat64(slots[fb + ib])) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BgtF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (msBitsFloat64(slots[fb + ia]) > msBitsFloat64(slots[fb + ib])) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BgeF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (msBitsFloat64(slots[fb + ia]) >= msBitsFloat64(slots[fb + ib])) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BltU64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if ((slots[fb + ia] as uint64) < (slots[fb + ib] as uint64)) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.BleU64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if ((slots[fb + ia] as uint64) <= (slots[fb + ib] as uint64)) ip = ip + (ic as int32);
				break;
			}
			case RaiserOpcode.AddF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = msFloat64Bits(msBitsFloat64(slots[fb + ib]) + msBitsFloat64(slots[fb + ic]));
				break;
			}
			case RaiserOpcode.SubF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = msFloat64Bits(msBitsFloat64(slots[fb + ib]) - msBitsFloat64(slots[fb + ic]));
				break;
			}
			case RaiserOpcode.MulF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = msFloat64Bits(msBitsFloat64(slots[fb + ib]) * msBitsFloat64(slots[fb + ic]));
				break;
			}
			case RaiserOpcode.DivF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = msFloat64Bits(msBitsFloat64(slots[fb + ib]) / msBitsFloat64(slots[fb + ic]));
				break;
			}
			case RaiserOpcode.NegF64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				slots[fb + ia] = msFloat64Bits(-msBitsFloat64(slots[fb + ib]));
				break;
			}
			case RaiserOpcode.AddI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const lhs = slots[fb + ib];
				const imm = immValue(ic);
				const sum = int64Bits((lhs as uint64) + (imm as uint64));
				if ((sum ^ lhs) >= 0 || (sum ^ imm) >= 0) { slots[fb + ia] = sum;
				} else { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return; }
				break;
			}
			case RaiserOpcode.SubI64Imm: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const lhs = slots[fb + ib];
				const imm = immValue(ic);
				const diff = int64Bits((lhs as uint64) - (imm as uint64));
				if ((diff ^ lhs) >= 0 || (diff ^ ~imm) >= 0) { slots[fb + ia] = diff;
				} else { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return; }
				break;
			}
			case RaiserOpcode.LoadField: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const handle = slots[fb + ib];
				if (handleTag(handle) == (RaiserHeapKind.Object as int64) && handleIndex(handle) < vm.objectHeap.objects.length) {
					const obj: Cursor<RaiserObjectData> = vm.objectHeap.objects[handleIndex(handle)];
					const idx = func.fieldCache[pc];
					if (idx >= 0 && idx < obj.slots.length && obj.classType.fieldIds[idx] == func.nameIds[ic]) {
						const cls = ia & 7;
						if ((cls == CLS_WORD || cls == CLS_FLOAT) && (slotKind(obj, idx) as int32) == cls) {
							slots[fb + (ia >> 3)] = obj.slots[idx];
						} else {
							slow = true;
						}
					} else {
						slow = true;
					}
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.StoreField: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const handle = slots[fb + ia];
				if (handleTag(handle) == (RaiserHeapKind.Object as int64) && handleIndex(handle) < vm.objectHeap.objects.length) {
					const obj: Cursor<RaiserObjectData> = vm.objectHeap.objects[handleIndex(handle)];
					const idx = func.fieldCache[pc];
					if (idx >= 0 && idx < obj.slots.length && obj.classType.fieldIds[idx] == func.nameIds[ib]) {
						const cls = ic & 7;
						if ((cls == CLS_WORD || cls == CLS_FLOAT) && (slotKind(obj, idx) as int32) == cls) {
							obj.slots[idx] = slots[fb + (ic >> 3)];
						} else {
							slow = true;
						}
					} else {
						slow = true;
					}
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.LoadSlot: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const handle = slots[fb + ib];
				const idx = ((word >> 56) & 255) as int32;
				if (handleTag(handle) == (RaiserHeapKind.Object as int64)) {
					when (mode != "danger") { if (handleIndex(handle) >= vm.objectHeap.objects.length) { slow = true; break; } }
					const obj: Cursor<RaiserObjectData> = vm.objectHeap.objects[handleIndex(handle)];
					if (idx >= obj.slots.length) { slow = true; break; }
					when (mode != "danger") { if (obj.classType.fields[idx] != func.names[ic]) { slow = true; break; } }
					const cls = ia & 7;
					if ((slotKind(obj, idx) as int32) != cls || cls == CLS_DYN) { slow = true; break; }
					if (cls == CLS_REF) writeRef(vm, fb + (ia >> 3), obj.slots[idx]);
					else slots[fb + (ia >> 3)] = obj.slots[idx];
				} else if (handleTag(handle) == (RaiserHeapKind.Seq as int64)) {
					const t = objectCellClass(handle);
					if (idx >= t.kinds.length) { slow = true; break; }
					when (mode != "danger") { if (t.fields[idx] != func.names[ic]) { slow = true; break; } }
					const cls = ia & 7;
					if ((t.kinds[idx] as int32) != cls || cls == CLS_DYN) { slow = true; break; }
					if (cls == CLS_REF) writeRef(vm, fb + (ia >> 3), objectCellSlot(seqCellOf(handle), idx));
					else slots[fb + (ia >> 3)] = objectCellSlot(seqCellOf(handle), idx);
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.StoreSlot: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const handle = slots[fb + ia];
				const idx = ((word >> 56) & 255) as int32;
				if (handleTag(handle) == (RaiserHeapKind.Object as int64)) {
					when (mode != "danger") { if (handleIndex(handle) >= vm.objectHeap.objects.length) { slow = true; break; } }
					const obj: Cursor<RaiserObjectData> = vm.objectHeap.objects[handleIndex(handle)];
					if (idx >= obj.slots.length) { slow = true; break; }
					when (mode != "danger") { if (obj.classType.fields[idx] != func.names[ib]) { slow = true; break; } }
					const cls = ic & 7;
					if ((slotKind(obj, idx) as int32) != cls || cls == CLS_DYN) { slow = true; break; }
					if (cls == CLS_REF) storeSlotRef(vm, obj, idx, slots[fb + (ic >> 3)]);
					else obj.slots[idx] = slots[fb + (ic >> 3)];
				} else if (handleTag(handle) == (RaiserHeapKind.Seq as int64)) {
					const t = objectCellClass(handle);
					if (idx >= t.kinds.length) { slow = true; break; }
					when (mode != "danger") { if (t.fields[idx] != func.names[ib]) { slow = true; break; } }
					const cls = ic & 7;
					if ((t.kinds[idx] as int32) != cls || cls == CLS_DYN) { slow = true; break; }
					if (cls == CLS_REF) storeCellRef(vm, seqCellOf(handle), idx, slots[fb + (ic >> 3)]);
					else objectCellSetSlot(seqCellOf(handle), idx, slots[fb + (ic >> 3)]);
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.LoadSlotW: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const handle = slots[fb + ib];
				const idx = ((word >> 56) & 255) as int32;
				if (handleTag(handle) == (RaiserHeapKind.Object as int64)) {
					when (mode != "danger") { if (handleIndex(handle) >= vm.objectHeap.objects.length) { slow = true; break; } }
					const obj: Cursor<RaiserObjectData> = objects[handleIndex(handle)];
					when (mode != "danger") { if (((obj.wordSlots >> (idx as int64)) & 1) == 0) { slow = true; break; } }
					when (mode == "danger") { if (idx >= obj.slots.length) { slow = true; break; } }
					when (mode != "danger") { if (obj.classType.fields[idx] != func.names[((word >> 40) & 65535) as int32]) { slow = true; break; } }
					slots[fb + ia] = obj.slots[idx];
				} else if (handleTag(handle) == (RaiserHeapKind.Seq as int64)) {
					when (mode != "danger") { const t = objectCellClass(handle); if (idx >= t.kinds.length || t.kinds[idx] != RaiserRegClass.Word || t.fields[idx] != func.names[((word >> 40) & 65535) as int32]) { slow = true; break; } }
					slots[fb + ia] = objectCellSlot(seqCellOf(handle), idx);
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.LoadSlotR: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const handle = slots[fb + ib];
				const idx = ((word >> 56) & 255) as int32;
				if (handleTag(handle) == (RaiserHeapKind.Object as int64)) {
					when (mode != "danger") { if (handleIndex(handle) >= vm.objectHeap.objects.length) { slow = true; break; } }
					const obj: Cursor<RaiserObjectData> = objects[handleIndex(handle)];
					when (mode != "danger") { if (((obj.refSlots >> (idx as int64)) & 1) == 0) { slow = true; break; } }
					when (mode == "danger") { if (idx >= obj.slots.length) { slow = true; break; } }
					when (mode != "danger") { if (obj.classType.fields[idx] != func.names[((word >> 40) & 65535) as int32]) { slow = true; break; } }
					writeRef(vm, fb + ia, obj.slots[idx]);
				} else if (handleTag(handle) == (RaiserHeapKind.Seq as int64)) {
					when (mode != "danger") { const t = objectCellClass(handle); if (idx >= t.kinds.length || t.kinds[idx] != RaiserRegClass.Ref || t.fields[idx] != func.names[((word >> 40) & 65535) as int32]) { slow = true; break; } }
					writeRef(vm, fb + ia, objectCellSlot(seqCellOf(handle), idx));
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.StoreSlotW: {
				const ia = ((word >> 8) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const handle = slots[fb + ia];
				const idx = ((word >> 56) & 255) as int32;
				if (handleTag(handle) == (RaiserHeapKind.Object as int64)) {
					when (mode != "danger") { if (handleIndex(handle) >= vm.objectHeap.objects.length) { slow = true; break; } }
					const obj: Cursor<RaiserObjectData> = objects[handleIndex(handle)];
					when (mode != "danger") { if (((obj.wordSlots >> (idx as int64)) & 1) == 0) { slow = true; break; } }
					when (mode == "danger") { if (idx >= obj.slots.length) { slow = true; break; } }
					when (mode != "danger") { if (obj.classType.fields[idx] != func.names[((word >> 24) & 65535) as int32]) { slow = true; break; } }
					obj.slots[idx] = slots[fb + ic];
				} else if (handleTag(handle) == (RaiserHeapKind.Seq as int64)) {
					when (mode != "danger") { const t = objectCellClass(handle); if (idx >= t.kinds.length || t.kinds[idx] != RaiserRegClass.Word || t.fields[idx] != func.names[((word >> 24) & 65535) as int32]) { slow = true; break; } }
					objectCellSetSlot(seqCellOf(handle), idx, slots[fb + ic]);
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.StoreSlotR: {
				const ia = ((word >> 8) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const handle = slots[fb + ia];
				const idx = ((word >> 56) & 255) as int32;
				if (handleTag(handle) == (RaiserHeapKind.Object as int64)) {
					when (mode != "danger") { if (handleIndex(handle) >= vm.objectHeap.objects.length) { slow = true; break; } }
					const obj: Cursor<RaiserObjectData> = objects[handleIndex(handle)];
					when (mode != "danger") { if (((obj.refSlots >> (idx as int64)) & 1) == 0) { slow = true; break; } }
					when (mode == "danger") { if (idx >= obj.slots.length) { slow = true; break; } }
					when (mode != "danger") { if (obj.classType.fields[idx] != func.names[((word >> 24) & 65535) as int32]) { slow = true; break; } }
					storeSlotRef(vm, obj, idx, slots[fb + ic]);
				} else if (handleTag(handle) == (RaiserHeapKind.Seq as int64)) {
					when (mode != "danger") { const t = objectCellClass(handle); if (idx >= t.kinds.length || t.kinds[idx] != RaiserRegClass.Ref || t.fields[idx] != func.names[((word >> 24) & 65535) as int32]) { slow = true; break; } }
					storeCellRef(vm, seqCellOf(handle), idx, slots[fb + ic]);
				} else {
					slow = true;
				}
				break;
			}
			case RaiserOpcode.AddI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const lhs = slots[fb + ib];
				const rhs = slots[fb + ic];
				const sum = int64Bits((lhs as uint64) + (rhs as uint64));
				if ((sum ^ lhs) >= 0 || (sum ^ rhs) >= 0) { slots[fb + ia] = sum;
				} else { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return; }
				break;
			}
			case RaiserOpcode.SubI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const lhs = slots[fb + ib];
				const rhs = slots[fb + ic];
				const diff = int64Bits((lhs as uint64) - (rhs as uint64));
				if ((diff ^ lhs) >= 0 || (diff ^ ~rhs) >= 0) { slots[fb + ia] = diff;
				} else { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return; }
				break;
			}
			case RaiserOpcode.MulI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const lhs = slots[fb + ib];
				const rhs = slots[fb + ic];
				if (mulOverflowsI64(lhs, rhs)) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return;
				} else { slots[fb + ia] = int64Bits((lhs as uint64) * (rhs as uint64)); }
				break;
			}
			case RaiserOpcode.DivI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const lhs = slots[fb + ib];
				const rhs = slots[fb + ic];
				if (rhs == 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "division by zero"); return;
				} else if (rhs == -1) {
					if (lhs == INT64_LOW) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return;
					} else { slots[fb + ia] = -lhs; }
				} else {
					slots[fb + ia] = lhs / rhs;
				}
				break;
			}
			case RaiserOpcode.ModI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ic] == 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "integer modulo by zero"); return;
				} else {
					slots[fb + ia] = slots[fb + ic] == -1 ? 0 : slots[fb + ib] % slots[fb + ic];
				}
				break;
			}
			case RaiserOpcode.DivU64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ic] == 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "division by zero"); return;
				} else {
					slots[fb + ia] = int64Bits((slots[fb + ib] as uint64) / (slots[fb + ic] as uint64));
				}
				break;
			}
			case RaiserOpcode.ModU64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				if (slots[fb + ic] == 0) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "integer modulo by zero"); return;
				} else {
					slots[fb + ia] = int64Bits((slots[fb + ib] as uint64) % (slots[fb + ic] as uint64));
				}
				break;
			}
			case RaiserOpcode.AddU64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = int64Bits((slots[fb + ib] as uint64) + (slots[fb + ic] as uint64));
				break;
			}
			case RaiserOpcode.SubU64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = int64Bits((slots[fb + ib] as uint64) - (slots[fb + ic] as uint64));
				break;
			}
			case RaiserOpcode.MulU64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = int64Bits((slots[fb + ib] as uint64) * (slots[fb + ic] as uint64));
				break;
			}
			case RaiserOpcode.NegI64: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const val = slots[fb + ib];
				if (val == INT64_LOW) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return;
				} else { slots[fb + ia] = -val; }
				break;
			}
			case RaiserOpcode.BitAnd: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = slots[fb + ib] & slots[fb + ic];
				break;
			}
			case RaiserOpcode.BitOr: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = slots[fb + ib] | slots[fb + ic];
				break;
			}
			case RaiserOpcode.BitXor: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = slots[fb + ib] ^ slots[fb + ic];
				break;
			}
			case RaiserOpcode.BitNot: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				slots[fb + ia] = ~slots[fb + ib];
				break;
			}
			case RaiserOpcode.ShiftLeft: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const count = (slots[fb + ic] & 63) as uint64;
				slots[fb + ia] = int64Bits((slots[fb + ib] as uint64) << count);
				break;
			}
			case RaiserOpcode.ShiftRight: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				slots[fb + ia] = slots[fb + ib] >> (slots[fb + ic] & 63);
				break;
			}
			case RaiserOpcode.ShiftRightU: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const count = (slots[fb + ic] & 63) as uint64;
				slots[fb + ia] = int64Bits((slots[fb + ib] as uint64) >> count);
				break;
			}
			case RaiserOpcode.NarrowU: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const width = ib as int64;
				slots[fb + ia] = slots[fb + ia] & (((1 as int64) << width) - 1);
				break;
			}
			case RaiserOpcode.NarrowS: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const ic = ((word >> 40) & 65535) as int32;
				const val = slots[fb + ia];
				const half = (1 as int64) << ((ib as int64) - 1);
				const low = ic == 1 ? 0 : -half;
				if (val < low || val >= low + 2 * half) { vm.ip = ip; vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget; vmError(vm, "over- or underflow"); return; }
				break;
			}
			case RaiserOpcode.SignExtend: {
				const ia = ((word >> 8) & 65535) as int32;
				const ib = ((word >> 24) & 65535) as int32;
				const imm = 64 - (ib as int64);
				const raised = int64Bits((slots[fb + ia] as uint64) << (imm as uint64));
				slots[fb + ia] = raised >> imm;
				break;
			}
			case RaiserOpcode.CallClosure: case RaiserOpcode.Move: case RaiserOpcode.Halt: case RaiserOpcode.Print: case RaiserOpcode.NewArray: case RaiserOpcode.LoadIndex: case RaiserOpcode.StoreIndex: case RaiserOpcode.ArrayLen: case RaiserOpcode.ArrayPush: case RaiserOpcode.ArraySetLen: case RaiserOpcode.NewObject: case RaiserOpcode.ConcatStr: case RaiserOpcode.EqStr: case RaiserOpcode.NeStr: case RaiserOpcode.StrLen: case RaiserOpcode.StrCharAt: case RaiserOpcode.StrSlice: case RaiserOpcode.CallHost: case RaiserOpcode.LtStr: case RaiserOpcode.LeStr: case RaiserOpcode.Yield: case RaiserOpcode.Spawn: case RaiserOpcode.Await: case RaiserOpcode.Try: case RaiserOpcode.Catch: case RaiserOpcode.Finally: case RaiserOpcode.FinallyEnd: case RaiserOpcode.Throw: case RaiserOpcode.Trap: case RaiserOpcode.Conv: case RaiserOpcode.CopyValue: case RaiserOpcode.StrByteLen: case RaiserOpcode.Sleep: case RaiserOpcode.ArraySlice: case RaiserOpcode.AddrReg: case RaiserOpcode.AddrGlobal: case RaiserOpcode.AddrIndex: case RaiserOpcode.AddrField: case RaiserOpcode.LoadDeref: case RaiserOpcode.StoreDeref: case RaiserOpcode.SameLoc: case RaiserOpcode.InstanceOf: case RaiserOpcode.ObjConv: case RaiserOpcode.UnionConv: case RaiserOpcode.ModuleImport: case RaiserOpcode.FutureNew: case RaiserOpcode.FutureSettle: case RaiserOpcode.FutureFail: case RaiserOpcode.FutureCombine: case RaiserOpcode.FutureThen: case RaiserOpcode.FutureRead: case RaiserOpcode.EqVal: case RaiserOpcode.NeVal: case RaiserOpcode.Box: case RaiserOpcode.Unbox: case RaiserOpcode.LitConv: case RaiserOpcode.ConcatStrR: case RaiserOpcode.StrByteAt: case RaiserOpcode.StrCharCodeAt: case RaiserOpcode.RcInc: case RaiserOpcode.RcDec: case RaiserOpcode.WasMoved: case RaiserOpcode.DestroyValue: case RaiserOpcode.SinkValue: case RaiserOpcode.AssignInPlace: case RaiserOpcode.RcHeld: case RaiserOpcode.RcKeptCheck: case RaiserOpcode.ArrayPop: case RaiserOpcode.ArrayShift: case RaiserOpcode.ArraySplice: case RaiserOpcode.ArraySplice3: case RaiserOpcode.ArrayReverse: case RaiserOpcode.ArraySort: case RaiserOpcode.ArrayFill: case RaiserOpcode.ArraySliceCopy: case RaiserOpcode.ArrayConcat: {
				slow = true;
				break;
			}
		}
		if (slow) {
			vm.ip = ip;
			vm.funcIdx = funcIdx; vm.base = fb; vm.loopCount = vm.loopLimit - budget;
			const ia = ((word >> 8) & 65535) as int32;
			const ib = ((word >> 24) & 65535) as int32;
			const ic = ((word >> 40) & 65535) as int32;
			const k = (op as int32) * 3;
			const ta = retag(OPERAND_KINDS[k], ia);
			const tb = retag(OPERAND_KINDS[k + 1], ib);
			const tc = retag(OPERAND_KINDS[k + 2], ic);
			if (vmStepHeap(vm, op, ta, tb, tc, func, pc)) {
				ip = vm.ip;
				if (vm.halted) { vmNoteSite(vm, func, pc); break; }
				slots = vm.regs.slots;
				objects = vm.objectHeap.objects;
			} else {
				vmStepSlow(vm, op, ta, tb, tc, func);
				if (vm.halted) vmNoteSite(vm, func, pc);
				if (vm.halted || vm.yielded) break;
				ip = vm.ip;
				fb = vm.base;
				if (vm.funcIdx != funcIdx) {
					funcIdx = vm.funcIdx;
					func = mod.functions[funcIdx];
					code = func.packed;
					if (code.length != func.code.length) assertPacked(func);
				}
				slots = vm.regs.slots;
				objects = vm.objectHeap.objects;
			}
			budget = vm.loopLimit - vm.loopCount;
		}
	}
}

// The indexed array opcodes on an array of the register's own element class, straight on the files; false leaves the
// instruction to the general handler.
function fastLoadIndex(vm: RaiserVM, ia: int32, ib: int32, ic: int32): boolean {
	const handle = vm.regs.slots[vm.base + (ib >> 3)];
	const idx = vm.regs.slots[vm.base + (ic >> 3)];
	if (!isSeqHandle(handle)) return false;
	const cell = seqCellOf(handle);
	when (mode != "danger") { if (!isLiveCell(cell)) return false; }
	const cls = ia & 7;
	if ((seqClass(cell) as int32) != cls || cls == CLS_DYN || idx < 0 || idx >= (seqLen(cell) as int64)) return false;
	if (cls == CLS_REF) writeRef(vm, vm.base + (ia >> 3), seqLoad(cell, idx as number));
	else vm.regs.slots[vm.base + (ia >> 3)] = seqLoad(cell, idx as number);
	return true;
}

function fastStoreIndex(vm: RaiserVM, ia: int32, ib: int32, ic: int32): boolean {
	const handle = vm.regs.slots[vm.base + (ia >> 3)];
	const idx = vm.regs.slots[vm.base + (ib >> 3)];
	if (!isSeqHandle(handle)) return false;
	const cell = seqCellOf(handle);
	when (mode != "danger") { if (!isLiveCell(cell)) return false; }
	const cls = ic & 7;
	if ((seqClass(cell) as int32) != cls || cls == CLS_DYN || idx < 0 || idx >= (seqLen(cell) as int64)) return false;
	if (cls == CLS_REF) {
		const held = vm.regs.slots[vm.base + (ic >> 3)];
		const old = seqLoad(cell, idx as number);
		if (old != held) {
			holdShell(vm, held);
			seqStore(cell, idx as number, held);
			releaseShell(vm, old);
		}
	} else {
		seqStore(cell, idx as number, vm.regs.slots[vm.base + (ic >> 3)]);
	}
	return true;
}

function fastArrayLen(vm: RaiserVM, ia: int32, ib: int32, ic: int32): boolean {
	const handle = vm.regs.slots[vm.base + (ib >> 3)];
	if (!isSeqHandle(handle)) return false;
	const cell = seqCellOf(handle);
	when (mode != "danger") { if (!isLiveCell(cell)) return false; }
	vm.regs.slots[vm.base + (ia >> 3)] = seqLen(cell) as int64;
	return true;
}

function fastArrayPush(vm: RaiserVM, ia: int32, ib: int32, ic: int32): boolean {
	const handle = vm.regs.slots[vm.base + (ia >> 3)];
	if (!isSeqHandle(handle)) return false;
	const cell = seqCellOf(handle);
	when (mode != "danger") { if (!isLiveCell(cell)) return false; }
	const cls = ib & 7;
	if ((seqClass(cell) as int32) != cls || cls == CLS_DYN || seqBase(cell) != 0) return false;
	if (cls == CLS_REF) {
		const held = vm.regs.slots[vm.base + (ib >> 3)];
		seqPush(vm.arrayHeap.mem, cell, held);
		holdShell(vm, held);
	} else {
		seqPush(vm.arrayHeap.mem, cell, vm.regs.slots[vm.base + (ib >> 3)]);
	}
	return true;
}

// A generic opcode, its register operands retagged. Heap opcodes answer true when handled here.
function vmStepHeap(vm: RaiserVM, op: RaiserOpcode, ia: int32, ib: int32, ic: int32, func: RaiserFunction, pc: int32): boolean {
	match (op) {
		RaiserOpcode.CopyValue => {
			const source = getDyn(vm, ib);
			const copied = copyTypedValue(vm.arrayHeap, vm.objectHeap, source, func.copyPlans, ic as int32);
			if (copied.kind >= RaiserValueKind.String && copied.intVal == source.intVal) rcIncrefHandle(vm.arrayHeap, vm.objectHeap, copied.intVal);
			setRegConform(vm, ia, copied);
				},
		RaiserOpcode.Box => {
			setRegConform(vm, ia, getReg(vm, ib));
		},
		RaiserOpcode.Unbox => {
			const source = getReg(vm, ib);
			const cls = ia & 7;
			if (ic == 1) {
				const inner = readDyn(vm.arrayHeap, source);
				if (cls != CLS_WORD) { vmError(vm, `internal: payload unbox into a ${regClassLetter(cls as RaiserRegClass)} register of ${func.name}`); return true; }
				vm.regs.slots[absOf(vm, ia)] = inner.kind == RaiserValueKind.Float ? msFloat64Bits(inner.floatVal) : inner.intVal;
			} else if (source.kind == RaiserValueKind.Box) {
				setRegConform(vm, ia, heapBoxValue(vm.arrayHeap, source.intVal));
			} else if (source.kind == RaiserValueKind.Nil && (cls == CLS_WORD || cls == CLS_FLOAT || cls == CLS_BOOL)) {
				vmError(vm, "internal: unbox of nil into the word register R" + (ia >> 3) + " of " + func.name);
			} else {
				setRegConform(vm, ia, source);
			}
		},
		RaiserOpcode.AddrReg => {
			setRegConform(vm, ia, { kind: RaiserValueKind.RegAddr, intVal: ((vm.regs.slots as int64) + ((absOf(vm, ib) as int64) << 3)) | ((ib & 7) as int64), floatVal: 0.0 });
		},
		RaiserOpcode.AddrGlobal => {
			setRegConform(vm, ia, { kind: RaiserValueKind.GlobalAddr, intVal: (ib * 256 + ic) as int64, floatVal: 0.0 });
		},
		RaiserOpcode.InstanceOf => {
			const held = getDyn(vm, ib);
			setRegBool(vm, ia, held.kind == RaiserValueKind.Object && raiserIsInstance(heapObjectClass(vm.objectHeap, held.intVal), getFuncConst(func, ic)));
		},
		RaiserOpcode.ObjConv => {
			const held = getDyn(vm, ia);
			if (held.kind != RaiserValueKind.Nil) {
				const classType = held.kind == RaiserValueKind.Object ? heapObjectClass(vm.objectHeap, held.intVal) : RAISER_NO_CLASS;
				if (!raiserIsInstance(classType, getFuncConst(func, ib))) {
					vmError(vm, "invalid object conversion: " + (classType.name != "" ? classType.name : held.kind == RaiserValueKind.Object ? "Object" : "<untyped>") + " is not " + constStringText(getFuncConst(func, ic)));
				}
			}
		},
		RaiserOpcode.LitConv => {
			const held = getDyn(vm, ia);
			if (held.kind != RaiserValueKind.Nil && !literalListHolds(vm.arrayHeap, constStringText(getFuncConst(func, ib)), held)) {
				const shown = held.kind == RaiserValueKind.String ? "\"" + heapStringText(vm.arrayHeap, held) + "\"" : raiserToString(vm.arrayHeap, held);
				vmError(vm, "invalid union conversion: " + shown + " is not " + constStringText(getFuncConst(func, ic)));
			}
		},
		RaiserOpcode.UnionConv => {
			const shown = unionConvRefusal(vm, getDyn(vm, ia), constStringText(getFuncConst(func, ib)));
			if (shown != "") vmError(vm, constStringText(getFuncConst(func, ic)) + shown + "'");
		},
		RaiserOpcode.SameLoc => {
			const l = getDyn(vm, ib);
			const r = getDyn(vm, ic);
			setRegBool(vm, ia, l.kind == r.kind && (l.kind == RaiserValueKind.String ? heapStringEquals(vm.arrayHeap, l, r) : l.intVal == r.intVal && l.floatVal == r.floatVal));
		},
		RaiserOpcode.IsKind => {
			const v = getDyn(vm, ib);
			setRegBool(vm, ia, ic < 64 ? (v.kind as number) == ic : v.kind == RaiserValueKind.Object && isClosurePair(heapObjectClass(vm.objectHeap, v.intVal)) == (ic == 64));
		},
		RaiserOpcode.AddrIndex => {
			vmHandleAddrIndex(vm, ia, ib, ic);
		},
		RaiserOpcode.AddrField => {
			const handle = vmHeapOperand(vm, getDyn(vm, ib), RaiserValueKind.Object, "an object");
			if (!vm.halted) setRegConform(vm, ia, raiserFieldAddrAt(handle, getFuncConst(func, ic).intVal));
		},
		RaiserOpcode.LoadDeref => {
			vmHandleLoadDeref(vm, ia, ib, ic);
		},
		RaiserOpcode.StoreDeref => {
			vmHandleStoreDeref(vm, func, pc, ia, ib, ic);
		},
		RaiserOpcode.Conv => {
			vmHandleConv(vm, ia, ib, ic);
		},
		RaiserOpcode.NewArray => {
			vmHandleNewArray(vm, func, pc, ia, ib, ic);
		},
		RaiserOpcode.LoadIndex => {
			if (!fastLoadIndex(vm, ia, ib, ic)) vmHandleLoadIndex(vm, ia, ib, ic);
		},
		RaiserOpcode.StoreIndex => {
			if (!fastStoreIndex(vm, ia, ib, ic)) vmHandleStoreIndex(vm, ia, ib, ic);
		},
		RaiserOpcode.ArrayLen => {
			if (!fastArrayLen(vm, ia, ib, ic)) vmHandleArrayLen(vm, ia, ib, ic);
		},
		RaiserOpcode.ArrayPush => {
			if (!fastArrayPush(vm, ia, ib, ic)) vmHandleArrayPush(vm, ia, ib, ic);
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
		RaiserOpcode.LoadSlot | RaiserOpcode.LoadSlotW | RaiserOpcode.LoadSlotR => {
			when (mode != "danger") { vmCheckSlot(vm, func, pc, ib, ic); }
			vmHandleLoadField(vm, func, pc, ia, ib, ic);
		},
		RaiserOpcode.StoreSlot | RaiserOpcode.StoreSlotW | RaiserOpcode.StoreSlotR => {
			when (mode != "danger") { vmCheckSlot(vm, func, pc, ia, ib); }
			vmHandleStoreField(vm, func, pc, ia, ib, ic);
		},
		RaiserOpcode.ConcatStr => {
			vmHandleConcatStr(vm, ia, ib, ic);
		},
		RaiserOpcode.EqVal => {
			vmHandleEqVal(vm, ia, ib, ic, true);
		},
		RaiserOpcode.NeVal => {
			vmHandleEqVal(vm, ia, ib, ic, false);
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
			const value = heapStringByteLength(vm.arrayHeap, getDyn(vm, ib));
			setRegInt(vm, ia, value);
		},
		RaiserOpcode.StrCharAt => {
			vmHandleStrCharAt(vm, ia, ib, ic);
		},
		RaiserOpcode.ConcatStrR => {
			vmHandleConcatStrR(vm, ia, ib, ic);
		},
		RaiserOpcode.StrByteAt => {
			setRegInt(vm, ia, heapHandleByteAt(vm.arrayHeap, vm.regs.slots[(ib >> 3) + vm.base], getReg(vm, ic).intVal));
		},
		RaiserOpcode.StrCharCodeAt => {
			setRegInt(vm, ia, heapHandleCharCodeAt(vm.arrayHeap, vm.regs.slots[(ib >> 3) + vm.base], getReg(vm, ic).intVal));
		},
		RaiserOpcode.StrSlice => {
			vmHandleStrSlice(vm, ia, ib, ic);
		},
		_ => {
			return false;
		},
	}
	return true;
}

function vmStepSlow(vm: RaiserVM, op: RaiserOpcode, ia: int32, ib: int32, ic: int32, func: RaiserFunction): void {
	match (op) {
		RaiserOpcode.Halt => {
			const haltVal = getDyn(vm, ia);
			if (ib == 2) {
				if (vm.current != 0) throw new Error("internal: the drain halt runs on the main strand");
				if (vmHasRunnable(vm) || vm.sched.timers.items.length > 0) {
					vm.exitValue = haltVal;
					vm.sched.strands.items[0].status = RaiserStrandStatus.Blocked;
					vm.sched.idleWait = true;
					vm.yielded = true;
				}
			} else if (ib != 1 && strandFinish(vm, haltVal)) {
				vm.yielded = true;
			} else {
				finishProgram(vm, haltVal, ib == 1);
			}
		},
		RaiserOpcode.Print => {
			const val = getReg(vm, ia);
			const s = raiserToString(vm.arrayHeap, val);
			vm.output = `${vm.output}${s}\n`;
			const sink = vm.printSink;
			if (sink != null) sink(s);
		},
		RaiserOpcode.Call | RaiserOpcode.CallDirect => {
			vmHandleCall(vm, ia, ib, ic);
		},
		RaiserOpcode.CallIndirect => {
			vmHandleCallIndirect(vm, ia, ib, ic);
		},
		RaiserOpcode.CallClosure | RaiserOpcode.CallClosureTyped => {
			vmHandleCallClosure(vm, ia, ib, ic);
		},
		RaiserOpcode.RcInc => {
			const handle = innerHandle(vm, vm.regs.slots[vm.base + ia]);
			if (handle != 0) rcIncrefHandle(vm.arrayHeap, vm.objectHeap, handle);
		},
		RaiserOpcode.RcDec => {
			vmRcDec(vm, ia, ib == 1);
		},
		RaiserOpcode.WasMoved => {
			if (inRefFile((ia & 7) as RaiserRegClass)) {
				const moved = vm.regs.slots[absOf(vm, ia)];
				vm.regs.slots[absOf(vm, ia)] = 0;
				if (ib == 1) vmFreeMovedCell(vm, moved);
				else releaseShell(vm, moved);
			} else vm.regs.slots[absOf(vm, ia)] = 0;
		},
		RaiserOpcode.DestroyValue => {
			vmDestroyValue(vm, ia, func.copyPlans, ic);
		},
		RaiserOpcode.SinkValue => {
			vmSinkValue(vm, ia, ib, func.copyPlans, ic);
		},
		RaiserOpcode.AssignInPlace => {
			vmAssignInPlace(vm, ia, ib, func.copyPlans, ic);
		},
		RaiserOpcode.RcHeld => {
			vm.regs.slots[absOf(vm, ib)] = rcCountOf(vm.arrayHeap, vm.objectHeap, innerHandle(vm, vm.regs.slots[vm.base + ia]));
		},
		RaiserOpcode.RcKeptCheck => {
			vmRcKeptCheck(vm, ia, ib);
		},
		RaiserOpcode.ArrayPop => {
			vmHandleArrayPop(vm, ia, ib);
		},
		RaiserOpcode.ArrayShift => {
			vmHandleArrayShift(vm, ia, ib, ic);
		},
		RaiserOpcode.ArraySplice => {
			vmHandleArraySplice(vm, ia, -1, ic);
		},
		RaiserOpcode.ArraySplice3 => {
			vmHandleArraySplice(vm, ia, ib, ic);
		},
		RaiserOpcode.ArrayReverse => {
			const handle = vmPlainArray(vm, ia, "reverse");
			if (handle >= 0) arrayHeldReverse(vm.arrayHeap, handle);
		},
		RaiserOpcode.ArraySort => {
			const handle = vmPlainArray(vm, ia, "sort");
			if (handle < 0) return;
			const refused = arrayHeldSort(vm.arrayHeap, handle);
			if (refused != "") vmError(vm, refused);
		},
		RaiserOpcode.ArrayFill => {
			vmHandleArrayFill(vm, ia, ib);
		},
		RaiserOpcode.ArraySliceCopy => {
			vmHandleArraySliceCopy(vm, ia, ib, ic);
		},
		RaiserOpcode.ArrayConcat => {
			vmHandleArrayConcat(vm, ia, ib, ic);
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
			const fut = vmSpawnClosure(vm, getDyn(vm, ib));
			if (fut >= 0) setRegConform(vm, ia, raiserFuture(fut));
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
			setRegConform(vm, ia, raiserFuture(newFuture(vm)));
		},
		RaiserOpcode.FutureSettle => {
			futureComplete(vm, getDyn(vm, ia).intVal, getDyn(vm, ib));
			if (ic == 1) {
				const consumed = getDyn(vm, ib);
				if (consumed.kind == RaiserValueKind.String || consumed.kind == RaiserValueKind.Array || consumed.kind == RaiserValueKind.Object) vmReleaseChild(vm, consumed.intVal, false);
			}
		},
		RaiserOpcode.FutureFail => {
			futureFail(vm, getDyn(vm, ia).intVal, vmExceptionText(vm, getDyn(vm, ib)), getDyn(vm, ib));
		},
		RaiserOpcode.FutureCombine => {
			vmHandleFutureCombine(vm, ia, ib, ic);
		},
		RaiserOpcode.FutureThen => {
			vmHandleFutureThen(vm, ia, ib, ic);
		},
		RaiserOpcode.FutureRead => {
			vmHandleFutureRead(vm, ia, ib, ic);
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
			enterFinally(vm, ia >> 3, ib, FINALLY_NORMAL, raiserNil());
		},
		RaiserOpcode.FinallyEnd => {
			const kind = vm.regs.slots[absOf(vm, ia)];
			const heldReg = operandTagged(ib, RaiserRegClass.Dyn);
			const held = getDyn(vm, heldReg);
			if (kind == FINALLY_RAISE) setException(vm, held);
			if (kind != FINALLY_NORMAL) {
				const marker = pendingMarker(absOf(vm, heldReg));
				if (vm.safePoints.length == safePointBase(vm) || vm.safePoints[vm.safePoints.length - 1] != marker) {
					vmError(vm, "internal: FinallyEnd found no pending marker for its box");
					return;
				}
				vm.safePoints.length = vm.safePoints.length - 1;
			}
			freePendingBox(vm, absOf(vm, heldReg) as int64);
			if (kind == FINALLY_RAISE) {
				unwindStep(vm);
			} else if (kind == FINALLY_RETURN) {
				vm.ip = held.intVal as int32;
			} else if (kind != FINALLY_NORMAL) {
				vmError(vm, `FinallyEnd: unknown routing ${kind}`);
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

// The frame of the callee begins at the first slot the call site names, so an argument whose class matches its
// parameter is already in place; one that differs is read out as a value first and then written into the callee's own
// class, because the two layouts overlap.
function enterCallee(vm: RaiserVM, dest: int32, calleeFuncIdx: number, site: int32, withoutLast: boolean = false): void {
	const caller = getModuleFunc(vm.mod, vm.funcIdx);
	const callee = vm.mod.functions[calleeFuncIdx];
	const blocks = caller.blocks;
	const argc = (blocks[site + 1] as int32) - (withoutLast ? 1 : 0);
	const sig = withoutLast ? sigPrefix(blocks[site + 2], argc) : blocks[site + 2];
	let args: RaiserValue[] | null = null;
	if (sig < 0 || argc >= callee.sigs.length || callee.sigs[argc] != sig) {
		args = [];
		for (let i = 0; i < argc; i += 1) args.push(getReg(vm, blocks[site + 3 + i] as int32));
	}
	const newBase = vm.base + (blocks[site] as int32);
	ensureSlots(vm.regs, newBase + callee.frameSize);
	enterRefs(vm, newBase as int64, caller, site, callee);

	const depth = vm.callStack.depth;
	if (depth == vm.callStack.items.length) {
		vm.callStack.items.push({ funcIdx: 0, returnIp: 0, returnDest: 0, base: 0, spBase: 0, refTop: 0 });
	}
	const frame = vm.callStack.items[depth];
	frame.funcIdx = vm.funcIdx;
	frame.returnIp = vm.ip;
	frame.returnDest = dest;
	frame.base = vm.base;
	frame.spBase = vm.safePoints.length as int32;
	frame.refTop = frameRefTop(vm, depth, vm.base, caller);
	vm.callStack.depth = depth + 1;
	enterBelow(vm, depth, newBase as int64, callee, frame);
	zeroOwnRefs(vm.regs.slots, newBase as int64, callee);

	vm.base = newBase as int32;
	vm.funcIdx = calleeFuncIdx as int32;
	vm.ip = 0;
	if (args != null) {
		const first = blocks[site] as int32;
		for (let i = 0; i < argc && i < callee.regOps.length; i += 1) {
			const cls = callee.regOps[i] & 7;
			if ((cls == CLS_REF || cls == CLS_DYN) && (first + i >= caller.frameSize || !inRefFile(caller.regClasses[first + i]))) vm.regs.slots[newBase + i] = 0;
			setRegConform(vm, callee.regOps[i], args[i]);
		}
	}
}

function vmHandleCall(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vm.callStack.depth >= MAX_CALL_DEPTH) {
		vmError(vm, `call stack overflow (depth ${MAX_CALL_DEPTH})`); return;
	}
	const calleeFuncIdx = ib;
	if (calleeFuncIdx < 0 || calleeFuncIdx >= vm.mod.functions.length) {
		vmError(vm, `function index out of bounds: ${calleeFuncIdx}`); return;
	}
	enterCallee(vm, ia, calleeFuncIdx as number, ic);
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
	const retVal = getDyn(vm, ia);
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

	if (vm.callStack.items[depth - 1].returnDest == DISPOSE_DEST) {
		vmFinishDestroy(vm, depth);
		return;
	}
	vm.callStack.depth = depth - 1;
	if (vm.safePoints.length != vm.callStack.items[depth - 1].spBase) {
		dropSafePoints(vm, vm.callStack.items[depth - 1].spBase);
	}

	const returned = getReg(vm, ia);
	const frame = vm.callStack.items[depth - 1];
	const callee = getModuleFunc(vm.mod, vm.funcIdx);
	const calleeBase = vm.base;

	vm.funcIdx = frame.funcIdx;
	vm.base = frame.base;
	vm.ip = frame.returnIp;
	setRegConform(vm, frame.returnDest, returned);
	leaveFrame(vm, calleeBase, callee, frame);
	leaveBelow(vm, depth - 1, calleeBase as int64, callee, frame);
}

// --- Destroying a cell whose last reference went ---
// The destroy routine of a class runs in a frame of its own whose return slot is DISPOSE_DEST, so its Ret
// takes the slow path to vmFinishDestroy, which frees the cell without walking it. A class without a routine,
// an array, a box and a string are walked here, each reference released through the same decrement.
// A destroy reached from inside a destroy defers once DROP_NEST_LIMIT are in flight and runs when they have returned,
// so a chain of any length never grows the frame stack or the host stack past that bound.

const DISPOSE_DEST: int32 = 7;
const DROP_NEST_LIMIT: int32 = 32;

function vmRcDec(vm: RaiserVM, ia: int32, cyclic: boolean): void {
	const abs = vm.base + ia;
	const handle = innerHandle(vm, vm.regs.slots[abs]);
	if (handle == 0) return;
	if (rcDecIsLast(vm.arrayHeap, vm.objectHeap, handle)) {
		if (handle == vm.regs.slots[abs]) vm.regs.slots[abs] = 0;
		else unshell(vm, abs);
		vmDestroyTop(vm, handle);
		vmDrain(vm);
	} else if (cyclic) {
		vmRegisterCyclic(vm, handle);
		vmDrain(vm);
	}
}

function vmRcKeptCheck(vm: RaiserVM, ia: int32, ib: int32): void {
	const handle = innerHandle(vm, vm.regs.slots[vm.base + ia]);
	if (rcCountOf(vm.arrayHeap, vm.objectHeap, handle) <= vm.regs.slots[absOf(vm, ib)]) return;
	const name = handleKind(handle) == RaiserValueKind.Object ? heapObjectClass(vm.objectHeap, handle).name : "cell";
	vmError(vm, `onDestroy kept a reference to the ${name} it destroys; that reference would dangle once the object is freed`);
}

// Every cell is freed here, so a collector that tracks cells has one place to forget them.
function vmFreeCell(vm: RaiserVM, handle: int64): void {
	orcUnregister(vm.arrayHeap, vm.objectHeap, handle);
	rcFreeHandle(vm.arrayHeap, vm.objectHeap, handle);
}

function vmDestroyFn(vm: RaiserVM, handle: int64): int32 {
	if (handleKind(handle) != RaiserValueKind.Object) return -1;
	return heapObjectClass(vm.objectHeap, handle).destroyFn;
}

function vmDestroyTop(vm: RaiserVM, handle: int64): void {
	const inFlight = vm.disposing.length + vm.dropNest;
	if (inFlight > 0 && (inFlight >= DROP_NEST_LIMIT || vm.callStack.depth + 2 >= MAX_CALL_DEPTH)) {
		vm.dropped.push(handle);
		return;
	}
	const fn = vmDestroyFn(vm, handle);
	if (fn >= 0) vmEnterDestroy(vm, handle, fn);
	else vmDestroyWalk(vm, handle);
}

function vmDestroyChild(vm: RaiserVM, handle: int64): void {
	if (vmDestroyFn(vm, handle) >= 0 || vm.dropNest >= DROP_NEST_LIMIT) vm.dropped.push(handle);
	else vmDestroyWalk(vm, handle);
}

function vmReleaseChild(vm: RaiserVM, handle: int64, cyclic: boolean): void {
	if (handle == 0) return;
	if (rcDecIsLast(vm.arrayHeap, vm.objectHeap, handle)) vmDestroyChild(vm, handle);
	else if (cyclic) vmRegisterCyclic(vm, handle);
}

function vmRegisterCyclic(vm: RaiserVM, handle: int64): void {
	if (!orcRegisterCandidate(vm.arrayHeap, vm.objectHeap, handle)) return;
	orcCollect(vm.arrayHeap, vm.objectHeap, (h: int64): void => { vm.dropped.push(h); });
}

function dynSlotCyclic(data: Cursor<RaiserObjectData>, valueIndex: int32): boolean {
	for (let s = 0; s < data.slots.length; s += 1) {
		if (data.classType.kinds[s] == RaiserRegClass.Dyn && data.slots[s] == valueIndex) return data.classType.cyclic[s];
	}
	return false;
}

function vmDestroyWalk(vm: RaiserVM, handle: int64): void {
	vm.dropNest += 1;
	vmReleaseContents(vm, handle);
	vmFreeCell(vm, handle);
	vm.dropNest -= 1;
}

function vmReleaseContents(vm: RaiserVM, handle: int64): void {
	const index = handleIndex(handle);
	match (handleHeapKind(handle)) {
		RaiserHeapKind.Object => {
			const data: Cursor<RaiserObjectData> = vm.objectHeap.objects[index];
			const kinds = data.classType.kinds;
			for (let i = 0; i < data.slots.length; i += 1) {
				if (kinds[i] == RaiserRegClass.Ref) {
					const child = data.slots[i];
					data.slots[i] = 0;
					if (!data.classType.uncounted[i]) vmReleaseChild(vm, child, data.classType.cyclic[i]);
				}
			}
			for (let i = 0; i < data.values.length; i += 1) {
				const held = data.values[i];
				if (held.kind >= RaiserValueKind.String) {
					data.values[i] = raiserNil();
					vmReleaseChild(vm, held.intVal, dynSlotCyclic(data, i));
				}
			}
		},
		RaiserHeapKind.Seq => {
			const c = seqCellOf(handle);
			const base = seqBase(c);
			if (isObjectCell(handle)) {
				const t = objectCellClass(handle);
				for (let i = 0; i < t.kinds.length; i += 1) {
					if (t.kinds[i] == RaiserRegClass.Dyn) {
						const held = objectCellFieldValue(vm.arrayHeap, handle, i);
						if (held.kind >= RaiserValueKind.String) {
							objectCellStoreField(vm.arrayHeap, handle, i, raiserNil());
							vmReleaseChild(vm, held.intVal, t.cyclic[i]);
						}
						continue;
					}
					if (t.kinds[i] != RaiserRegClass.Ref) continue;
					const child = objectCellSlot(c, i);
					objectCellSetSlot(c, i, 0);
					if (!t.uncounted[i]) vmReleaseChild(vm, child, t.cyclic[i]);
				}
			} else if (base == 0 && !seqUncounted(c) && seqClass(c) == RaiserRegClass.Ref) {
				const cyclic = seqCyclic(c);
				for (let i = 0; i < seqLen(c); i += 1) {
					const child = seqLoad(c, i);
					seqStore(c, i, 0);
					if (child != 0) vmReleaseChild(vm, child, cyclic);
				}
			} else if (base == 0 && !seqUncounted(c) && seqClass(c) == RaiserRegClass.Dyn) {
				const cyclic = seqCyclic(c);
				for (let i = 0; i < seqLen(c); i += 1) {
					const held = arrayHeldAt(vm.arrayHeap, handle, i);
					if (held.kind < RaiserValueKind.String) continue;
					arrayHeldStore(vm.arrayHeap, handle, i, raiserNil());
					vmReleaseChild(vm, held.intVal, cyclic);
				}
			}
		},
		RaiserHeapKind.Box => {
			const held = heapBoxValue(vm.arrayHeap, handle);
			if (held.kind >= RaiserValueKind.String) vmReleaseChild(vm, held.intVal, false);
		},
		RaiserHeapKind.String => {},
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => { throw new Error(`internal: handle ${handle} names no cell to destroy`); },
	}
}

// Runs the deferred destroys once none is in flight, stopping at the first that enters a routine's frame,
// whose return comes back here.
function vmDrain(vm: RaiserVM): void {
	while (vm.dropped.length > 0 && vm.disposing.length == 0 && vm.dropNest == 0) {
		const handle = vm.dropped.pop();
		vmDestroyTop(vm, handle);
	}
}

function vmEnterDestroy(vm: RaiserVM, handle: int64, fn: int32): void {
	const callee = vm.mod.functions[fn];
	if (callee.arity < 1 || callee.regClasses.length == 0 || !inRefFile(callee.regClasses[0])) {
		throw new Error(`internal: destroy routine ${callee.name} does not take the cell as its first ref parameter`);
	}
	if (vm.callStack.depth >= MAX_CALL_DEPTH) {
		vmError(vm, `call stack overflow (depth ${MAX_CALL_DEPTH})`);
		return;
	}
	const caller = getModuleFunc(vm.mod, vm.funcIdx);
	const newBase = vm.base + caller.frameSize;
	ensureSlots(vm.regs, newBase + callee.frameSize);
	const depth = vm.callStack.depth;
	if (depth == vm.callStack.items.length) {
		vm.callStack.items.push({ funcIdx: 0, returnIp: 0, returnDest: 0, base: 0, spBase: 0, refTop: 0 });
	}
	const frame = vm.callStack.items[depth];
	frame.funcIdx = vm.funcIdx;
	frame.returnIp = vm.ip;
	frame.returnDest = DISPOSE_DEST;
	frame.base = vm.base;
	frame.spBase = vm.safePoints.length as int32;
	frame.refTop = frameRefTop(vm, depth, vm.base, caller);
	vm.callStack.depth = depth + 1;
	enterBelow(vm, depth, newBase as int64, callee, frame);
	zeroOwnRefs(vm.regs.slots, newBase as int64, callee);
	vm.base = newBase;
	vm.funcIdx = fn;
	vm.ip = 0;
	vm.regs.slots[newBase] = handle;
	heapObjectSetRc(vm.objectHeap, handle, 1);
	vm.disposing.push(handle);
}

function vmFinishDestroy(vm: RaiserVM, depth: int32): void {
	const frame = vm.callStack.items[depth - 1];
	const callee = getModuleFunc(vm.mod, vm.funcIdx);
	const calleeBase = vm.base;
	vm.regs.slots[vm.base] = 0;
	vm.callStack.depth = depth - 1;
	dropSafePoints(vm, frame.spBase);
	vm.funcIdx = frame.funcIdx;
	vm.base = frame.base;
	vm.ip = frame.returnIp;
	leaveFrame(vm, calleeBase, callee, frame);
	leaveBelow(vm, depth - 1, calleeBase as int64, callee, frame);
	vmFreeCell(vm, vm.disposing.pop());
	vmDrain(vm);
}

// A struct, tuple or array held by value is destroyed by its copy plan: the plan names which children are
// aggregates it owns (destroyed in turn and freed) and leaves the others to the dynamic release of one reference.
// A cell its count says another holder still has stays.
// A user move hook took the contents of a struct cell its source register held alone: the cell is freed as it
// stands, because the hook decided what became of the fields, as the zeroed source of a move does in the reference.
function vmFreeMovedCell(vm: RaiserVM, moved: int64): void {
	const sole = moved == 0 || !isShell(moved) || heapBoxRc(moved) <= 1;
	const inner = innerHandle(vm, moved);
	releaseShell(vm, moved);
	if (!sole || inner == 0 || !rcDecIsLast(vm.arrayHeap, vm.objectHeap, inner)) return;
	vm.dropNest += 1;
	vmFreeCell(vm, inner);
	vm.dropNest -= 1;
}

function vmDestroyAggregate(vm: RaiserVM, handle: int64, plans: RaiserCopyPlan[], planIndex: int32): void {
	if (handle == 0 || !rcDecIsLast(vm.arrayHeap, vm.objectHeap, handle)) return;
	vm.dropNest += 1;
	vmReleaseByPlan(vm, handle, plans, planIndex);
	vmFreeCell(vm, handle);
	vm.dropNest -= 1;
}

function vmReleasePlanned(vm: RaiserVM, handle: int64, plans: RaiserCopyPlan[], child: int32, cyclic: boolean): void {
	if (handle == 0) return;
	if (child >= 0 && plans[child].kind != RaiserCopyKind.Preserve) vmDestroyAggregate(vm, handle, plans, child);
	else vmReleaseChild(vm, handle, cyclic);
}

function vmReleaseByPlan(vm: RaiserVM, handle: int64, plans: RaiserCopyPlan[], planIndex: int32): void {
	const plan = plans[planIndex];
	const kind = isObjectCell(handle) ? RaiserHeapKind.Object : handleHeapKind(handle);
	const index = handleIndex(handle);
	if (plan.kind == RaiserCopyKind.Array && kind == RaiserHeapKind.Seq) {
		const c = seqCellOf(handle);
		const base = seqBase(c);
		if (base != 0) {
			vmReleaseChild(vm, base, false);
		} else if (!seqUncounted(c) && seqClass(c) == RaiserRegClass.Ref) {
			const cyclic = seqCyclic(c);
			for (let i = 0; i < seqLen(c); i += 1) {
				const held = seqLoad(c, i);
				seqStore(c, i, 0);
				vmReleasePlanned(vm, held, plans, plan.children[0], cyclic);
			}
		} else if (!seqUncounted(c) && seqClass(c) == RaiserRegClass.Dyn) {
			const cyclic = seqCyclic(c);
			for (let i = 0; i < seqLen(c); i += 1) {
				const held = arrayHeldAt(vm.arrayHeap, handle, i);
				if (held.kind < RaiserValueKind.String) continue;
				arrayHeldStore(vm.arrayHeap, handle, i, raiserNil());
				vmReleasePlanned(vm, held.intVal, plans, plan.children[0], cyclic);
			}
		}
	} else if (plan.kind == RaiserCopyKind.Object && kind == RaiserHeapKind.Object) {
		const classType = heapObjectClass(vm.objectHeap, handle);
		const laid = heapObjectLaidCount(vm.objectHeap, handle);
		const count = heapObjectFieldCount(vm.objectHeap, handle);
		for (let f = 0; f < count; f += 1) {
			const held = heapObjectFieldValueAt(vm.arrayHeap, vm.objectHeap, handle, f);
			if (held.kind < RaiserValueKind.String) continue;
			if (f < laid && classType.uncounted[f]) continue;
			const name = heapObjectFieldNameAt(vm.objectHeap, handle, f);
			let child: int32 = -1;
			for (let i = 0; i < plan.names.length; i += 1) {
				if (plan.names[i] == name) {
					child = plan.children[i];
					break;
				}
			}
			vmReleasePlanned(vm, held.intVal, plans, child, f < laid && classType.cyclic[f]);
		}
	} else if (plan.kind == RaiserCopyKind.Union && kind == RaiserHeapKind.Object) {
		const discriminant = heapObjectGetField(vm.arrayHeap, vm.objectHeap, handle, plan.names[0]);
		let arm: int32 = -1;
		for (let i = 0; i < plan.discriminants.length; i += 1) {
			if (discriminant.kind != RaiserValueKind.Nil && plan.discriminants[i] == discriminant.intVal) arm = plan.children[i];
		}
		if (arm >= 0) vmReleaseByPlan(vm, handle, plans, arm);
		else vmReleaseContents(vm, handle);
	} else {
		vmReleaseContents(vm, handle);
	}
}

function vmDestroyValue(vm: RaiserVM, ia: int32, plans: RaiserCopyPlan[], planIndex: int32): void {
	const abs = vm.base + ia;
	const shelled = vm.regs.slots[abs];
	const handle = innerHandle(vm, shelled);
	vm.regs.slots[abs] = 0;
	releaseShell(vm, shelled);
	vmDestroyAggregate(vm, handle, plans, planIndex);
	vmDrain(vm);
}

function vmSinkValue(vm: RaiserVM, ia: int32, ib: int32, plans: RaiserCopyPlan[], planIndex: int32): void {
	const oldShell = vm.regs.slots[vm.base + ia];
	const next = vm.regs.slots[vm.base + ib];
	if (oldShell == next) return;
	holdShell(vm, next);
	vm.regs.slots[vm.base + ia] = next;
	releaseShell(vm, oldShell);
	vmDestroyAggregate(vm, innerHandle(vm, oldShell), plans, planIndex);
	vmDrain(vm);
}

function vmAssignInPlace(vm: RaiserVM, ia: int32, ib: int32, plans: RaiserCopyPlan[], planIndex: int32): void {
	const destShell = vm.regs.slots[vm.base + ia];
	const sourceShell = vm.regs.slots[vm.base + ib];
	const dest = innerHandle(vm, destShell);
	const source = innerHandle(vm, sourceShell);
	if (dest == source) return;
	const kind = handleHeapKind(dest);
	if (dest == 0 || source == 0 || kind != handleHeapKind(source) || (kind != RaiserHeapKind.Seq && kind != RaiserHeapKind.Object)) {
		vmError(vm, "internal: AssignInPlace needs two cells of one aggregate kind");
		return;
	}
	if (rcCountOf(vm.arrayHeap, vm.objectHeap, source) != 1) {
		vmError(vm, "internal: AssignInPlace takes a sole-owned source");
		return;
	}
	vm.dropNest += 1;
	vmReleaseByPlan(vm, dest, plans, planIndex);
	const d = handleIndex(dest);
	const s = handleIndex(source);
	if (isObjectCell(dest) != isObjectCell(source)) {
		throw new Error("internal: AssignInPlace between an object cell and an array cell");
	} else if (isObjectCell(dest)) {
		if (cellTypeIndex(seqCellOf(dest)) != cellTypeIndex(seqCellOf(source))) throw new Error(`internal: AssignInPlace between a ${objectCellClass(dest).name} cell and a ${objectCellClass(source).name} cell`);
		for (let i = 0; i < objectCellClass(dest).fields.length; i += 1) {
			const word = objectCellSlot(seqCellOf(dest), i);
			objectCellSetSlot(seqCellOf(dest), i, objectCellSlot(seqCellOf(source), i));
			objectCellSetSlot(seqCellOf(source), i, word);
		}
	} else if (kind == RaiserHeapKind.Seq) {
		const dc = seqCellOf(dest);
		const sc = seqCellOf(source);
		if (seqBase(dc) != 0 || seqBase(sc) != 0) throw new Error("internal: AssignInPlace over a view");
		const views = vm.arrayHeap.seqViews.get(dest);
		const offsets: int64[] = [];
		if (views != null) for (const view of views) offsets.push(seqViewOffset(seqCellOf(view)));
		seqSwapContents(dc, sc);
		if (views != null) for (let v = 0; v < views.length; v += 1) seqPointViewInto(seqCellOf(views[v]), offsets[v]);
	} else {
		const to: Cursor<RaiserObjectData> = vm.objectHeap.objects[d];
		const from: Cursor<RaiserObjectData> = vm.objectHeap.objects[s];
		const slots = to.slots; to.slots = from.slots; from.slots = slots;
		const wordSlots = to.wordSlots; to.wordSlots = from.wordSlots; from.wordSlots = wordSlots;
		const refSlots = to.refSlots; to.refSlots = from.refSlots; from.refSlots = refSlots;
		const values = to.values; to.values = from.values; from.values = values;
		const added = to.added; to.added = from.added; from.added = added;
		const classType = to.classType; to.classType = from.classType; from.classType = classType;
	}
	vm.regs.slots[vm.base + ib] = 0;
	releaseShell(vm, sourceShell);
	vmFreeCell(vm, source);
	vm.dropNest -= 1;
	vmDrain(vm);
}

function vmHandleCallIndirect(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vm.callStack.depth >= MAX_CALL_DEPTH) {
		vmError(vm, `call stack overflow (depth ${MAX_CALL_DEPTH})`); return;
	}
	const calleeFuncIdx = vm.regs.slots[absOf(vm, ib)];
	if (calleeFuncIdx < 0 || calleeFuncIdx >= vm.mod.functions.length) {
		vmError(vm, `function index out of bounds: ${calleeFuncIdx}`); return;
	}
	enterCallee(vm, ia, calleeFuncIdx as number, ic);
}

function vmHandleCallClosure(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (vm.callStack.depth >= MAX_CALL_DEPTH) {
		vmError(vm, `call stack overflow (depth ${MAX_CALL_DEPTH})`); return;
	}
	const handle = vmHeapOperand(vm, getDyn(vm, ib), RaiserValueKind.Object, "an object");
	if (vm.halted) return;
	const fn = heapObjectGetField(vm.arrayHeap, vm.objectHeap, handle, "fn");
	if (fn.kind != RaiserValueKind.Int || fn.intVal < 0 || fn.intVal >= vm.mod.functions.length) {
		vmError(vm, `function index out of bounds: ${fn.intVal}`); return;
	}
	const env = heapObjectGetField(vm.arrayHeap, vm.objectHeap, handle, "env");
	const caller = getModuleFunc(vm.mod, vm.funcIdx);
	if (env.kind != RaiserValueKind.Nil) setRegConform(vm, caller.blocks[ic + 2 + caller.blocks[ic + 1]] as int32, env);
	enterCallee(vm, ia, fn.intVal as number, ic, env.kind == RaiserValueKind.Nil);
}

// --- Array opcode handlers ---

function vmHandleNewArray(vm: RaiserVM, func: RaiserFunction, pc: int32, ia: int32, ib: int32, ic: int32): void {
	const slot = ((func.packed[pc] >> 56) & 255) as number;
	const handle = heapAllocArrayOf(vm.arrayHeap, slotArrayClass(slot), slotArrayWidth(slot));
	heapArraySetFlags(vm.arrayHeap, handle, slotArrayCyclic(slot), slotArrayUncounted(slot));
	const elemCount = ib;
	for (let i = 0; i < elemCount; i = i + 1) {
		const elem = getDyn(vm, func.blocks[ic + 3 + i] as int32);
		if (vmElemRefused(vm, handle, elem)) return;
		heapArrayPush(vm.arrayHeap, handle, elem);
		vmIncref(vm, elem);
	}
	setRegRef(vm, ia, RaiserValueKind.Array, handle);
}

function vmNoteSite(vm: RaiserVM, func: RaiserFunction, pc: int32): void {
	if ((vm.error.startsWith("expected a") || vm.error.startsWith("array handle out of bounds")) && !vm.error.includes(" (in ")) vm.error = `internal: ${vm.error} (in ${func.name} at instruction ${pc})`;
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

// Whether the array cannot hold the value; the run stops with the reason. A view holds what the array it stands on does.
function vmElemRefused(vm: RaiserVM, handle: int64, val: RaiserValue): boolean {
	const refused = arrayRefusal(vm.arrayHeap, handle, val);
	if (refused == "") return false;
	vmError(vm, refused);
	return true;
}

function vmArrayHandleOk(vm: RaiserVM, handle: int64): boolean {
	if (isSeqHandle(handle) && isLiveCell(seqCellOf(handle))) return true;
	vmError(vm, `array handle out of bounds: ${handle}`);
	return false;
}

function vmElemIndex(vm: RaiserVM, handle: int64, idx: int64): boolean {
	if (!vmArrayHandleOk(vm, handle)) return false;
	const arrLen = heapArrayLen(vm.arrayHeap, handle);
	if (idx < 0 || idx >= arrLen) {
		vmError(vm, `index ${idx} out of bounds (length ${arrLen})`); return false;
	}
	return true;
}

function vmHandleAddrIndex(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const handle = vmHeapOperand(vm, getDyn(vm, ib), RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	const idx = getDyn(vm, ic).intVal;
	if (!vmElemIndex(vm, handle, idx)) return;
	const cell = seqCellOf(handle);
	if (seqBase(cell) != 0) {
		setRegConform(vm, ia, raiserElemAddr(seqBase(cell), seqViewOffset(cell) + idx));
		return;
	}
	setRegConform(vm, ia, raiserElemAddr(handle, idx));
}

function vmHandleLoadDeref(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const ptr = getDyn(vm, ib);
	let held = ptr;
	if (ptr.kind == RaiserValueKind.RegAddr) {
		held = readAbs(vm, (ptr.intVal & 7) as int32, regIndex(vm, ptr.intVal));
	} else if (ptr.kind == RaiserValueKind.GlobalAddr) {
		held = vm.globals[ptr.intVal];
	} else if (ptr.kind == RaiserValueKind.ElemAddr) {
		if (!vmElemIndex(vm, ptr.intVal, ptr.floatVal as int64)) return;
		held = heapArrayGet(vm.arrayHeap, ptr.intVal, ptr.floatVal as int64);
	} else if (ptr.kind == RaiserValueKind.FieldAddr) {
		held = heapObjectGetField(vm.arrayHeap, vm.objectHeap, ptr.intVal, fieldAddrName(ptr));
	} else if (ptr.kind == RaiserValueKind.Nil) {
		vmError(vm, "attempt to read through a nil pointer"); return;
	}
	setRegConform(vm, ia, held);
}

function vmHandleStoreDeref(vm: RaiserVM, func: RaiserFunction, pc: int32, ia: int32, ib: int32, ic: int32): void {
	const ptr = getDyn(vm, ia);
	const held = getReg(vm, ic);
	const val = ptr.kind == RaiserValueKind.RegAddr || ptr.kind == RaiserValueKind.GlobalAddr ? held : readDyn(vm.arrayHeap, held);
	if (ptr.kind == RaiserValueKind.RegAddr || ptr.kind == RaiserValueKind.GlobalAddr) {
		if (ptr.kind == RaiserValueKind.RegAddr) {
			writeAbs(vm, (ptr.intVal & 7) as int32, regIndex(vm, ptr.intVal), val);
		} else {
			vmIncref(vm, val);
			vmDecref(vm, vm.globals[ptr.intVal]);
			vm.globals[ptr.intVal] = val;
		}
	} else if (ptr.kind == RaiserValueKind.ElemAddr) {
		const idx = ptr.floatVal as int64;
		if (!vmElemIndex(vm, ptr.intVal, idx)) return;
		if (vmElemRefused(vm, ptr.intVal, val)) return;
		vmIncref(vm, val);
		vmDecref(vm, heapArrayGet(vm.arrayHeap, ptr.intVal, idx));
		heapArraySet(vm.arrayHeap, ptr.intVal, idx, val);
	} else if (ptr.kind == RaiserValueKind.FieldAddr) {
		const idx = heapObjectFieldIndex(vm.objectHeap, ptr.intVal, fieldAddrName(ptr));
		if (idx >= 0) {
			vmStoreFieldAt(vm, ptr.intVal, idx, val);
		} else if (isObjectCell(ptr.intVal)) {
			vmError(vm, `internal: ${objectCellClass(ptr.intVal).name} has no field '${fieldAddrName(ptr)}' and a laid object takes none past its layout`);
		} else {
			vmIncref(vm, val);
			heapObjectAppendField(vm.objectHeap, ptr.intVal, fieldAddrName(ptr), val);
		}
	} else if (ptr.kind == RaiserValueKind.Nil) {
		vmError(vm, "attempt to write through a nil pointer");
	} else if (ptr.kind == RaiserValueKind.Array && val.kind == RaiserValueKind.Nil) {
		const handle = vmHeapOperand(vm, ptr, RaiserValueKind.Array, "an array");
		if (vm.halted || !vmArrayHandleOk(vm, handle)) return;
		heapArraySetLen(vm.arrayHeap, handle, 0);
	} else {
		vmError(vm, `internal: cannot write through a value of kind ${ptr.kind}: it is not a location (in ${func.name} at instruction ${pc})`);
	}
}

function vmHandleLoadIndex(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getDyn(vm, ib);
	const idxVal = getDyn(vm, ic);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	const idx = idxVal.intVal;
	if (!vmArrayHandleOk(vm, handle)) return;
	const arrLen = heapArrayLen(vm.arrayHeap, handle);
	if (idx < 0 || idx >= arrLen) {
		vmError(vm, `index ${idx} out of bounds (length ${arrLen})`); return;
	}
	setRegConform(vm, ia, heapArrayGet(vm.arrayHeap, handle, idx));
}

function vmHandleStoreIndex(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getDyn(vm, ia);
	const idxVal = getDyn(vm, ib);
	const val = getDyn(vm, ic);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	const idx = idxVal.intVal;
	if (!vmArrayHandleOk(vm, handle)) return;
	const arrLen = heapArrayLen(vm.arrayHeap, handle);
	if (idx < 0 || idx >= arrLen) {
		vmError(vm, `index ${idx} out of bounds (length ${arrLen})`); return;
	}
	if (vmElemRefused(vm, handle, val)) return;
	vmIncref(vm, val);
	vmDecref(vm, heapArrayGet(vm.arrayHeap, handle, idx));
	heapArraySet(vm.arrayHeap, handle, idx, val);
}

function vmHandleArrayLen(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getDyn(vm, ib);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	if (!vmArrayHandleOk(vm, handle)) return;
	const len = heapArrayLen(vm.arrayHeap, handle);
	setRegInt(vm, ia, len as int64);
}

function vmHandleArrayPush(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getDyn(vm, ia);
	const val = getDyn(vm, ib);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	if (!vmArrayHandleOk(vm, handle)) return;
	if (heapArrayIsView(vm.arrayHeap, handle)) {
		vmError(vm, "cannot push to a slice"); return;
	}
	if (vmElemRefused(vm, handle, val)) return;
	heapArrayPush(vm.arrayHeap, handle, val);
	vmIncref(vm, val);
}

// --- Array kernels: the std operations that rewrite or copy a reference-holding array ---
// A kernel that makes another holder of an element counts it, and one that evicts an element releases it, in
// through the shared increment and decrement.

function vmPlainArray(vm: RaiserVM, t: int32, verb: string): int64 {
	const handle = vmHeapOperand(vm, getDyn(vm, t), RaiserValueKind.Array, "an array");
	if (vm.halted) return -1;
	if (!vmArrayHandleOk(vm, handle)) return -1;
	if (heapArrayIsView(vm.arrayHeap, handle)) {
		vmError(vm, `cannot ${verb} a slice`); return -1;
	}
	return handle;
}

function vmShareHold(vm: RaiserVM, val: RaiserValue): void {
	if (val.kind < RaiserValueKind.String) return;
	rcIncrefHandle(vm.arrayHeap, vm.objectHeap, val.intVal);
}

function vmEvict(vm: RaiserVM, val: RaiserValue, cyclic: boolean): void {
	if (val.kind < RaiserValueKind.String) return;
	vmReleaseChild(vm, val.intVal, cyclic);
}

function vmEvictAll(vm: RaiserVM, evicted: RaiserValue[], cyclic: boolean): void {
	for (const val of evicted) vmEvict(vm, val, cyclic);
	vmDrain(vm);
}

function vmHandleArrayPop(vm: RaiserVM, ia: int32, ib: int32): void {
	const handle = vmPlainArray(vm, ib, "pop from");
	if (handle < 0) return;
	const n = arrayHeldCount(vm.arrayHeap, handle);
	if (n == 0) {
		vmError(vm, "index -1 out of bounds (length 0)"); return;
	}
	const val = arrayHeldAt(vm.arrayHeap, handle, n - 1);
	heapArraySetLen(vm.arrayHeap, handle, (n - 1) as int64);
	setRegConform(vm, ia, val);
	vmDecref(vm, val);
}

function vmHandleArrayShift(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const handle = vmPlainArray(vm, ib, "shift");
	if (handle < 0) return;
	const cls = heapArrayClass(vm.arrayHeap, handle);
	if (arrayHeldCount(vm.arrayHeap, handle) == 0) {
		let zero = raiserNil();
		if (cls == RaiserRegClass.Word) zero = raiserInt(0);
		else if (cls == RaiserRegClass.Float) zero = raiserFloat(0.0);
		else if (cls == RaiserRegClass.Bool) zero = raiserBool(false);
		else if (ic == 1) zero = heapAllocString(vm.arrayHeap, "");
		setRegConform(vm, ia, zero);
		return;
	}
	const val = arrayHeldAt(vm.arrayHeap, handle, 0);
	arrayHeldRemove(vm.arrayHeap, handle, 0, 1);
	setRegConform(vm, ia, val);
	vmDecref(vm, val);
}

// itemReg < 0 is the removal alone; otherwise the item goes in where the removal began.
function vmHandleArraySplice(vm: RaiserVM, ia: int32, itemReg: int32, ic: int32): void {
	const handle = vmPlainArray(vm, ia, "splice");
	if (handle < 0) return;
	const uncounted = heapArrayUncounted(vm.arrayHeap, handle);
	let start = getDyn(vm, ic).intVal;
	let count = getDyn(vm, ic + 8).intVal;
	const inserting = itemReg >= 0;
	let item = raiserNil();
	if (inserting) {
		item = getDyn(vm, itemReg);
		if (vmElemRefused(vm, handle, item)) return;
		if (start < 0) start = 0;
	}
	const n = arrayHeldCount(vm.arrayHeap, handle) as int64;
	const evicted: RaiserValue[] = [];
	if (start >= 0 && start < n && count > 0) {
		if (count > n - start) count = n - start;
		for (let i = 0; i < count; i += 1) evicted.push(arrayHeldAt(vm.arrayHeap, handle, (start + i) as number));
		arrayHeldRemove(vm.arrayHeap, handle, start as number, count as number);
	}
	if (inserting) {
		const length = arrayHeldCount(vm.arrayHeap, handle) as int64;
		const at = start < length ? start : length;
		if (!uncounted) vmShareHold(vm, item);
		arrayHeldInsert(vm.arrayHeap, handle, at as number, item);
	}
	vmEvictAll(vm, uncounted ? [] : evicted, heapArrayCyclic(vm.arrayHeap, handle));
}

function vmHandleArrayFill(vm: RaiserVM, ia: int32, ib: int32): void {
	const handle = vmPlainArray(vm, ia, "fill");
	if (handle < 0) return;
	const val = getDyn(vm, ib);
	if (vmElemRefused(vm, handle, val)) return;
	const uncounted = heapArrayUncounted(vm.arrayHeap, handle);
	const evicted: RaiserValue[] = [];
	for (let i = 0; i < arrayHeldCount(vm.arrayHeap, handle); i += 1) {
		evicted.push(arrayHeldAt(vm.arrayHeap, handle, i));
		if (!uncounted) vmShareHold(vm, val);
		heapArraySet(vm.arrayHeap, handle, i as int64, val);
	}
	vmEvictAll(vm, uncounted ? [] : evicted, heapArrayCyclic(vm.arrayHeap, handle));
}

function vmSourceArray(vm: RaiserVM, t: int32): int64 {
	const handle = vmHeapOperand(vm, getDyn(vm, t), RaiserValueKind.Array, "an array");
	if (vm.halted) return -1;
	if (!vmArrayHandleOk(vm, handle)) return -1;
	return handle;
}

function vmNewArrayLike(vm: RaiserVM, source: int64): int64 {
	return heapAllocArrayLike(vm.arrayHeap, vm.arrayHeap, source);
}

function vmCopyElements(vm: RaiserVM, from: int64, start: int64, end: int64, into: int64): void {
	for (let i = start; i < end; i += 1) {
		const val = heapArrayGet(vm.arrayHeap, from, i);
		heapArrayPush(vm.arrayHeap, into, val);
		if (!heapArrayUncounted(vm.arrayHeap, into)) vmShareHold(vm, val);
	}
}

function vmHandleArraySliceCopy(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const source = vmSourceArray(vm, ib);
	if (source < 0) return;
	const len = heapArrayLen(vm.arrayHeap, source) as int64;
	let start = getDyn(vm, ic).intVal;
	let end = getDyn(vm, ic + 8).intVal;
	if (start < 0) start = len + start;
	if (end < 0) end = len + end;
	if (start < 0) start = 0;
	if (end > len) end = len;
	const handle = vmNewArrayLike(vm, source);
	if (start < end) vmCopyElements(vm, source, start, end, handle);
	setRegRef(vm, ia, RaiserValueKind.Array, handle);
}

function vmHandleArrayConcat(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const left = vmSourceArray(vm, ib);
	if (left < 0) return;
	const right = vmSourceArray(vm, ic);
	if (right < 0) return;
	const leftClass = heapArrayClass(vm.arrayHeap, left);
	const rightClass = heapArrayClass(vm.arrayHeap, right);
	if (leftClass != rightClass) {
		vmError(vm, `internal: concat of an array of ${regClassLetter(leftClass)} elements with one of ${regClassLetter(rightClass)} elements`); return;
	}
	const handle = vmNewArrayLike(vm, left);
	vmCopyElements(vm, left, 0, heapArrayLen(vm.arrayHeap, left) as int64, handle);
	vmCopyElements(vm, right, 0, heapArrayLen(vm.arrayHeap, right) as int64, handle);
	setRegRef(vm, ia, RaiserValueKind.Array, handle);
}

function vmHandleArraySetLen(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const arrVal = getDyn(vm, ia);
	const lenVal = getDyn(vm, ib);
	const handle = vmHeapOperand(vm, arrVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	if (!vmArrayHandleOk(vm, handle)) return;
	if (lenVal.kind != RaiserValueKind.Int) {
		vmError(vm, `ArraySetLen expected an integer length, got kind ${lenVal.kind}`); return;
	}
	if (ic == 1) {
		if (lenVal.intVal < 0 || lenVal.intVal > MAX_ARRAY_COUNT) vmError(vm, `value ${lenVal.intVal} not in range 0 .. ${MAX_ARRAY_COUNT}`);
		return;
	}
	if (heapArrayIsView(vm.arrayHeap, handle)) {
		vmError(vm, "cannot set the length of a slice"); return;
	}
	const evicted: RaiserValue[] = [];
	if (arrayHoldsHandles(vm.arrayHeap, handle)) {
		for (let i = (lenVal.intVal < 0 ? 0 : lenVal.intVal) as number; i < arrayHeldCount(vm.arrayHeap, handle); i += 1) evicted.push(arrayHeldAt(vm.arrayHeap, handle, i));
	}
	heapArraySetLen(vm.arrayHeap, handle, lenVal.intVal);
	vmEvictAll(vm, evicted, heapArrayCyclic(vm.arrayHeap, handle));
}

function vmHandleArraySlice(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const srcVal = getDyn(vm, ib);
	const start = getDyn(vm, ic).intVal;
	const end = getDyn(vm, ic + 8).intVal;
	const handle = vmHeapOperand(vm, srcVal, RaiserValueKind.Array, "an array");
	if (vm.halted) return;
	if (!vmArrayHandleOk(vm, handle)) return;
	const len = heapArrayLen(vm.arrayHeap, handle);
	if (end != start && (start < 0 || end < start || end > len)) {
		vmError(vm, `slice ${start}..${end} out of bounds (length ${len})`); return;
	}
	let base = srcVal;
	let off = start;
	const cell = seqCellOf(handle);
	if (seqBase(cell) != 0) {
		base = handleValue(seqBase(cell));
		off = seqViewOffset(cell) + start;
	}
	const view = heapAllocView(vm.arrayHeap, base, off, (end - start) as int32);
	vmIncref(vm, base);
	setRegRef(vm, ia, RaiserValueKind.Array, view);
}

// --- Object opcode handlers ---

function vmHandleNewObject(vm: RaiserVM, ia: int32, ib: int32, func: RaiserFunction): void {
	if (ib > 0 && (func.classTypes[ib - 1].fields.length > 0 || func.classTypes[ib - 1].destroyFn >= 0)) {
		const cell = heapNewObjectCell(vm.arrayHeap.mem, func.classTypes[ib - 1], OWNED_BY_RECEIVER_RC as int64);
		setRegRef(vm, ia, RaiserValueKind.Object, objectCellHandle(cell));
		return;
	}
	const handle = heapAllocObject(vm.objectHeap);
	if (ib > 0) {
		layOutObject(vm.objectHeap.objects[handleIndex(handle)], func.classTypes[ib - 1]);
	}
	setRegRef(vm, ia, RaiserValueKind.Object, handle);
}

function vmHandleLoadField(vm: RaiserVM, func: RaiserFunction, pc: int32, ia: int32, ib: int32, ic: int32): void {
	const objVal = getDyn(vm, ib);
	const handle = vmHeapOperand(vm, objVal, RaiserValueKind.Object, "an object");
	if (vm.halted) return;
	if (!isObjectCell(handle) && handleIndex(handle) >= vm.objectHeap.objects.length) {
		vmError(vm, `object handle out of bounds: ${handle}`); return;
	}
	const idx = cachedFieldIndexOf(vm, func, pc, handle, ic);
	setRegConform(vm, ia, idx >= 0 ? heapObjectFieldValueAt(vm.arrayHeap, vm.objectHeap, handle, idx) : raiserNil());
}

function cachedFieldIndexOf(vm: RaiserVM, func: RaiserFunction, pc: int32, handle: int64, ni: int32): int32 {
	if (!isObjectCell(handle)) return cachedFieldIndex(func, pc, vm.objectHeap.objects[handleIndex(handle)], ni);
	const t = objectCellClass(handle);
	const cached = func.fieldCache[pc];
	if (cached >= 0 && cached < t.fields.length && t.fieldIds[cached] == func.nameIds[ni]) return cached;
	const found = t.fields.indexOf(func.names[ni]) as int32;
	if (found >= 0) func.fieldCache[pc] = found;
	return found;
}

// The position of field `names[ni]` in `obj`, -1 when it has none. A laid slot hits on the
// interned id of its name; a field past the layout and a miss compare text, and a found
// position is remembered at `pc`.
function cachedFieldIndex(func: RaiserFunction, pc: int32, obj: RaiserObjectData, ni: int32): int32 {
	const cached = func.fieldCache[pc];
	const laid = obj.slots.length as int32;
	if (cached >= 0 && cached < laid) {
		if (obj.classType.fieldIds[cached] == func.nameIds[ni]) return cached;
	} else if (cached >= laid && cached - laid < obj.added.length) {
		if (obj.added[cached - laid] == func.names[ni]) return cached;
	}
	const found = fieldIndex(obj, func.names[ni]) as int32;
	if (found >= 0) func.fieldCache[pc] = found;
	return found;
}

function vmHandleStoreField(vm: RaiserVM, func: RaiserFunction, pc: int32, ia: int32, ib: int32, ic: int32): void {
	const objVal = getDyn(vm, ia);
	const handle = vmHeapOperand(vm, objVal, RaiserValueKind.Object, "an object");
	if (vm.halted) return;
	if (!isObjectCell(handle) && handleIndex(handle) >= vm.objectHeap.objects.length) {
		vmError(vm, `object handle out of bounds: ${handle}`); return;
	}
	const val = getDyn(vm, ic);
	const idx = cachedFieldIndexOf(vm, func, pc, handle, ib);
	if (idx >= 0) {
		vmStoreFieldAt(vm, handle, idx, val);
		return;
	}
	if (isObjectCell(handle)) {
		vmError(vm, `internal: ${objectCellClass(handle).name} has no field '${func.names[ib]}' and a laid object takes none past its layout`);
		return;
	}
	vmIncref(vm, val);
	const count = heapObjectFieldCount(vm.objectHeap, handle);
	heapObjectAppendField(vm.objectHeap, handle, func.names[ib], val);
	func.fieldCache[pc] = count;
}

// The counted store of a value into field `idx`: the field holds the new value before it gives up the old one.
function vmStoreFieldAt(vm: RaiserVM, handle: int64, idx: number, val: RaiserValue): void {
	const refused = heapObjectFieldRefusal(vm.objectHeap, handle, idx, val);
	if (refused != "") { vmError(vm, refused); return; }
	vmIncref(vm, val);
	const old = heapObjectFieldValueAt(vm.arrayHeap, vm.objectHeap, handle, idx as int64);
	heapObjectStoreFieldAt(vm.arrayHeap, vm.objectHeap, handle, idx, val);
	vmDecref(vm, old);
}

// A slot opcode reads an object NewObject laid out at the slot its receiver's type
// gives the field, and the danger build does so without comparing the name. An object
// the host built keeps its own field order and is read by name.
function vmCheckSlot(vm: RaiserVM, func: RaiserFunction, pc: int32, objReg: int32, name: int32): void {
	const held = getDyn(vm, objReg);
	if (held.kind != RaiserValueKind.Object || (!isObjectCell(held.intVal) && handleIndex(held.intVal) >= vm.objectHeap.objects.length)) return;
	const classType = heapObjectClass(vm.objectHeap, held.intVal);
	const slot = ((func.packed[pc] >> 56) & 255) as int32;
	if (slot < classType.fields.length && classType.fields[slot] != func.names[name]) {
		vmError(vm, `internal: ${func.name} reads '${func.names[name]}' at slot ${slot} of a ${classType.name != "" ? classType.name : "typed object"} that holds '${classType.fields[slot]}' there, so the receiver's type does not fix its layout`);
	}
}

// --- String opcode handlers ---
// Every handler reads its source text before it writes the destination: the
// destination write releases the old value, which may be the source's own string.

function vmHandleConcatStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const lhs = getDyn(vm, ib);
	const rhs = getDyn(vm, ic);
	if (lhs.kind == RaiserValueKind.String && rhs.kind == RaiserValueKind.String) {
		if (ia == ib && heapStringHeldOnce(vm.arrayHeap, lhs) && rhs.intVal != lhs.intVal) {
			heapAppend(vm.arrayHeap, lhs.intVal, rhs);
			return;
		}
		setRegRef(vm, ia, RaiserValueKind.String, heapConcat(vm.arrayHeap, lhs, rhs).intVal);
		return;
	}
	const replaced = ia == ib && (ia & 7) == CLS_REF && lhs.kind == RaiserValueKind.String ? lhs.intVal : 0;
	setRegString(vm, ia, raiserToString(vm.arrayHeap, lhs) + raiserToString(vm.arrayHeap, rhs));
	if (replaced != 0 && rcDecIsLast(vm.arrayHeap, vm.objectHeap, replaced)) vmDestroyTop(vm, replaced);
}

// With the destination also the left operand, the register owns one count of the text it held: an append extends
// that string in place while it is held once, as msStringAppend does, and otherwise swaps in the joined copy and
// releases the old one.
function vmHandleConcatStrR(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const lhs = vm.regs.slots[(ib >> 3) + vm.base];
	const rhs = vm.regs.slots[(ic >> 3) + vm.base];
	if (ia == ib && heapHandleHeldOnce(vm.arrayHeap, lhs) && rhs != lhs) {
		heapAppendHandle(vm.arrayHeap, lhs, rhs);
		return;
	}
	writeRef(vm, (ia >> 3) + vm.base, heapConcatHandles(vm.arrayHeap, lhs, rhs));
	if (ia == ib && handleHeapKind(lhs) == RaiserHeapKind.String && rcDecIsLast(vm.arrayHeap, vm.objectHeap, lhs)) vmDestroyTop(vm, lhs);
}

function vmHandleEqVal(vm: RaiserVM, ia: int32, ib: int32, ic: int32, wanted: boolean): void {
	if (raiserEqual(vm.arrayHeap, getDyn(vm, ia), getDyn(vm, ib)) == wanted) {
		vm.ip = vm.ip + (ic as int32);
	}
}

function vmHandleEqStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (heapStringEquals(vm.arrayHeap, getDyn(vm, ia), getDyn(vm, ib))) {
		vm.ip = vm.ip + (ic as int32);
	}
}

function vmHandleNeStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (!heapStringEquals(vm.arrayHeap, getDyn(vm, ia), getDyn(vm, ib))) {
		vm.ip = vm.ip + (ic as int32);
	}
}

function vmHandleLtStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (heapStringLess(vm.arrayHeap, getDyn(vm, ia), getDyn(vm, ib))) {
		vm.ip = vm.ip + (ic as int32);
	}
}

function vmHandleLeStr(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	if (heapStringLessEq(vm.arrayHeap, getDyn(vm, ia), getDyn(vm, ib))) {
		vm.ip = vm.ip + (ic as int32);
	}
}

// --- String method handlers ---

function vmHandleStrLen(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const length = heapStringLength(vm.arrayHeap, getDyn(vm, ib));
	setRegInt(vm, ia, length);
}

function vmHandleStrCharAt(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const source = getDyn(vm, ib);
	const i = getDyn(vm, ic).intVal;
	setRegString(vm, ia, i >= 0 && i < heapStringLength(vm.arrayHeap, source) ? heapStringSlice(vm.arrayHeap, source, i as int32, (i + 1) as int32) : "");
}

function vmHandleStrSlice(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const source = getDyn(vm, ib);
	const start = getDyn(vm, ic).intVal;
	const end = getDyn(vm, ic + 8).intVal;
	setRegString(vm, ia, heapStringSlice(vm.arrayHeap, source, start as int32, end as int32));
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
		setRegInt(vm, ia, src.floatVal as int64);
		return;
	}
	if (src.intVal < 0 || src.intVal > 255) {
		vmError(vm, `value ${fromUnsigned ? `${src.intVal as uint64}` : `${src.intVal}`} not in range 0 .. 255`);
		return;
	}
	setRegInt(vm, ia, src.intVal);
}

function vmHandleConv(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const src = getDyn(vm, ib);
	const cls = convTarget(ic);
	const fromUnsigned = convSource(ic) == (RaiserConvClass.U64 as int32);
	if (cls == RaiserConvClass.F64Bits) {
		setRegInt(vm, ia, msFloat64Bits(asNum(src)));
		return;
	}
	if (cls == RaiserConvClass.F64 && convSource(ic) == (RaiserConvClass.F64Bits as int32)) {
		setRegFloat(vm, ia, msBitsFloat64(src.intVal));
		return;
	}
	if (cls == RaiserConvClass.I32Wrap) {
		setRegInt(vm, ia, msToInt32(asNum(src)) as int64);
		return;
	}
	if (cls == RaiserConvClass.HandleBits) {
		if (src.kind == RaiserValueKind.Nil) {
			setRegInt(vm, ia, 0);
		} else if (src.kind == RaiserValueKind.Object || src.kind == RaiserValueKind.Array) {
			setRegInt(vm, ia, src.intVal);
		} else {
			vmError(vm, `no identity bits for a value of kind ${src.kind}`);
		}
		return;
	}
	if (cls == RaiserConvClass.F64 || cls == RaiserConvClass.F32) {
		setRegFloat(vm, ia, convToFloat(src, fromUnsigned, cls == RaiserConvClass.F32));
		return;
	}
	if (cls == RaiserConvClass.Str && convSource(ic) == (RaiserConvClass.Char as int32)) {
		setRegString(vm, ia, fromCodePoint(src.intVal >= 0 && src.intVal < 0x80 ? src.intVal as int32 : 0xFFFD));
		return;
	}
	if (cls == RaiserConvClass.Str) {
		setRegString(vm, ia, fromUnsigned && src.kind == RaiserValueKind.Int ? `${src.intVal as uint64}` : raiserToString(vm.arrayHeap, src));
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
		setRegInt(vm, ia, int64Bits(src.floatVal as uint64));
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
		setRegInt(vm, ia, whole);
		return;
	}
	if (signed) {
		if (whole < lo || whole > hi) {
			vmError(vm, `value ${whole} not in range ${lo} .. ${hi}`);
			return;
		}
		setRegInt(vm, ia, whole);
		return;
	}
	setRegInt(vm, ia, whole & (((1 as int64) << (bits as int64)) - 1));
}

// --- Bitwise handlers ---

// using int64_t casts — MetaScript fallback not needed.

// --- CallHost handler ---
// Generic name-resolved native call. The only host-call mechanism. A call
// site resolves its registry entry once, into func.hostCache at its constant
// index; the registered wrappers (in src/compiler/meta/hostTable.ms) own all
// type-specific marshalling.

function resolveHostEntry(vm: RaiserVM, func: RaiserFunction, ib: int32): HostEntry | null {
	const nameConst = getFuncConst(func, ib);
	if (nameConst.kind != RaiserValueKind.String) {
		vmError(vm, `CallHost expected string constant at index ${ib}, got kind ${nameConst.kind}`);
		return null;
	}
	const name = func.names[ib];
	const found = lookupHost(name);
	if (found == null) {
		vmError(vm, `Unknown host function: ${name}`);
		return null;
	}
	func.hostCache[ib] = found;
	return found;
}

function vmHandleCallHost(vm: RaiserVM, ia: int32, ib: int32, ic: int32): void {
	const func = getModuleFunc(vm.mod, vm.funcIdx);
	let entry = func.hostCache[ib];
	if (entry == null || !entry.live) {
		entry = resolveHostEntry(vm, func, ib);
		if (entry == null) return;
	}
	if (vm.hostCallsRestricted && !hostEntryAllowedInRestrictedMode(entry)) {
		vmError(vm, `Restricted dependency compile-time code '${vm.hostPolicySource}' cannot call host function '${entry.name}'`);
		return;
	}
	if (vm.comptime && hostEntrySpawnsChild(entry)) {
		vmError(vm, "spawn is not available in compile-time evaluation: the child process would outlive the build");
		return;
	}
	const fn = entry.fn;

	const argc = func.blocks[ic + 1] as int32;
	const args: RaiserValue[] = [];
	let i = 0;
	while (i < argc) {
		args.push(getDyn(vm, func.blocks[ic + 3 + i] as int32));
		i = i + 1;
	}

	// Save/restore so a bridge that re-enters a nested VM leaves the outer
	// VM's heaps active when it resumes.
	const prevObjHeap = activeHostObjectHeap();
	const prevArrHeap = activeHostArrayHeap();
	const prevArgv = activeProgramArgv();
	setActiveHostHeaps(vm.objectHeap, vm.arrayHeap);
	setActiveProgramArgv(vm.programArgv);
	const outerFloor = vm.floor;
	const suspended = vm.suspendedRuns.length;
	vm.floor = Math.max(1, vm.base + getModuleFunc(vm.mod, vm.funcIdx).frameSize);
	const result = fn(args);
	if (vm.suspendedRuns.length > suspended) {
		resumeRun(vm, vm.suspendedRuns[suspended]);
		vm.suspendedRuns.shrink(suspended);
	}
	vm.floor = outerFloor;
	setActiveHostHeaps(prevObjHeap, prevArrHeap);
	setActiveProgramArgv(prevArgv);

	const fatal = hostRaiseIsFatal();
	const raised = takeHostRaise();
	if (raised != null) {
		if (fatal) {
			vmError(vm, raised);
			return;
		}
		const error = heapAllocObject(vm.objectHeap);
		const name = heapAllocString(vm.arrayHeap, "Error");
		const message = heapAllocString(vm.arrayHeap, raised);
		vmIncref(vm, name);
		vmIncref(vm, message);
		heapObjectSetField(vm.objectHeap, error, "name", name);
		heapObjectSetField(vm.objectHeap, error, "message", message);
		setException(vm, raiserObject(error));
		unwindStep(vm);
		return;
	}

	setRegConform(vm, ia, result);
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

function classedModule(code: RaiserInstruction[], constants: RaiserValue[], classes: RaiserRegClass[]): RaiserModule {
	const func = createRaiserFunction("classed", code, constants, 0, 0, classes.length, classes);
	return createRaiserModule("classed", [func], 0);
}

test "a register write of a kind its class does not hold names the register, its class and the kind" {
	const word = execModule(classedModule(
		[raiserABC(RaiserOpcode.LoadNil, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
		[],
		[RaiserRegClass.Word, RaiserRegClass.Dyn]
	));
	assert word.error.indexOf("internal: register R0 of classed is Word, got Nil") >= 0, word.error;
	const boxed = execModule(classedModule(
		[raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABC(RaiserOpcode.Box, 1, 0, 0), raiserABC(RaiserOpcode.LoadNil, 2, 0, 0), raiserABC(RaiserOpcode.Halt, 1, 0, 0)],
		[raiserInt(3)],
		[RaiserRegClass.Word, RaiserRegClass.Dyn, RaiserRegClass.Dyn]
	));
	assert boxed.error == "", boxed.error;
	assert boxed.exitValue.kind == RaiserValueKind.Int && boxed.exitValue.intVal == 3;
}

test "an argument of a kind its parameter class does not hold is refused at the call" {
	const callee = createRaiserFunction("callee", [raiserABC(RaiserOpcode.Ret, 0, 0, 0)], [], 1, 1, 1, [RaiserRegClass.Ref]);
	const entry = createRaiserFunction("entry", [
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABC(RaiserOpcode.Call, 0, 1, 1),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserInt(3)], 0, 0, 2, [RaiserRegClass.Dyn, RaiserRegClass.Word]);
	const vm = execModule(createRaiserModule("call", [entry, callee], 0));
	assert vm.error.indexOf("internal: register R0 of callee is Ref, got Int") >= 0, vm.error;
}

test "Unbox reads a box into a word register and Box leaves nil and a box as they are" {
	const round = execModule(classedModule(
		[raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABC(RaiserOpcode.Box, 1, 0, 0), raiserABC(RaiserOpcode.Unbox, 2, 1, 0), raiserABC(RaiserOpcode.Halt, 2, 0, 0)],
		[raiserInt(9)],
		[RaiserRegClass.Word, RaiserRegClass.Dyn, RaiserRegClass.Word]
	));
	assert round.error == "", round.error;
	assert round.exitValue.kind == RaiserValueKind.Int && round.exitValue.intVal == 9;
	const again = execModule(classedModule(
		[raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABC(RaiserOpcode.Box, 1, 0, 0), raiserABC(RaiserOpcode.Box, 2, 1, 0), raiserABC(RaiserOpcode.LoadNil, 3, 0, 0), raiserABC(RaiserOpcode.Box, 3, 3, 0), raiserABC(RaiserOpcode.Halt, 2, 0, 0)],
		[raiserInt(4)],
		[RaiserRegClass.Word, RaiserRegClass.Dyn, RaiserRegClass.Dyn, RaiserRegClass.Dyn]
	));
	assert again.error == "", again.error;
	assert again.exitValue.intVal == 4;
	assert heapBoxLive(again.arrayHeap) == 1;
}

test "Unbox of nil into a word register names the register" {
	const vm = execModule(classedModule(
		[raiserABC(RaiserOpcode.LoadNil, 0, 0, 0), raiserABC(RaiserOpcode.Unbox, 1, 0, 0), raiserABC(RaiserOpcode.Halt, 1, 0, 0)],
		[],
		[RaiserRegClass.Dyn, RaiserRegClass.Word]
	));
	assert vm.error.indexOf("internal: unbox of nil into the word register R1 of classed") >= 0, vm.error;
}

test "Unbox into a ref register reads a boxed run-time string back" {
	const vm = execModule(classedModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABx(RaiserOpcode.LoadConst, 1, 0), raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),
			raiserABC(RaiserOpcode.Box, 3, 2, 0), raiserABC(RaiserOpcode.Unbox, 4, 3, 0), raiserABC(RaiserOpcode.StrLen, 5, 4, 0), raiserABC(RaiserOpcode.Halt, 5, 0, 0),
		],
		[raiserConstString("ab")],
		[RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Dyn, RaiserRegClass.Ref, RaiserRegClass.Word]
	));
	assert vm.error == "", vm.error;
	assert vm.exitValue.intVal == 4;
}

test "a global declared a word before its initializer ran reads as its typed zero" {
	const mod = classedModule(
		[raiserABx(RaiserOpcode.LoadGlobal, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
		[],
		[RaiserRegClass.Word, RaiserRegClass.Dyn]
	);
	mod.globalCount = 1;
	mod.globalInit = [raiserInt(0)];
	const vm = execModule(mod);
	assert vm.error == "", vm.error;
	assert vm.exitValue.kind == RaiserValueKind.Int && vm.exitValue.intVal == 0;
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

test "bits converted to a float are the IEEE pattern, not the integer's value" {
	const fromBits = RaiserConvClass.F64Bits as int32;
	assert execConv(raiserInt(4609434218613702656), RaiserConvClass.F64, fromBits).exitValue.floatVal == 1.5;
	assert execConv(raiserInt(-4616189618054758400), RaiserConvClass.F64, fromBits).exitValue.floatVal == -1.0;
	assert execConv(raiserInt(1), RaiserConvClass.F64, fromBits).exitValue.floatVal == 5e-324;
}

test "a reference converted to its identity bits is its handle, and nil is zero" {
	assert execConv(raiserObject(makeHandle(7, RaiserHeapKind.Object)), RaiserConvClass.HandleBits).exitValue.intVal == makeHandle(7, RaiserHeapKind.Object);
	assert execConv(raiserArray(makeHandle(3, RaiserHeapKind.Object)), RaiserConvClass.HandleBits).exitValue.intVal == makeHandle(3, RaiserHeapKind.Object);
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
	const vm = createVM(mod);
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
	assert vm.error == "value -1 not in range 0 .. 2147483647";
}

test "ArraySetLen with C = 1 refuses a count past 2^31 - 1" {
	const vm = execModule(makeTestModule(
		[
			raiserABC(RaiserOpcode.NewArray, 0, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABC(RaiserOpcode.ArraySetLen, 0, 1, 1),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserInt(2147483648)]
	));
	assert vm.error == "value 2147483648 not in range 0 .. 2147483647";
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
	assert vm.error == "", vm.error;
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

function eqValSkips(op: RaiserOpcode, a: RaiserValue, b: RaiserValue): boolean {
	const vm = execModule(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABx(RaiserOpcode.LoadConst, 2, 2),
			raiserABC(op, 0, 1, 1),
			raiserABx(RaiserOpcode.LoadConst, 2, 3),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[a, b, raiserInt(1), raiserInt(0)]
	));
	return vm.exitValue.intVal == 1;
}

test "EqVal and NeVal compare by kind and payload, a string by its text" {
	assert eqValSkips(RaiserOpcode.EqVal, raiserConstString("ab"), raiserConstString("ab"));
	assert !eqValSkips(RaiserOpcode.EqVal, raiserConstString("ab"), raiserConstString("xy"));
	assert eqValSkips(RaiserOpcode.NeVal, raiserConstString("ab"), raiserConstString("xy"));
	assert !eqValSkips(RaiserOpcode.NeVal, raiserConstString("ab"), raiserConstString("ab"));
	assert !eqValSkips(RaiserOpcode.EqVal, raiserFloat(3.5), raiserFloat(4.5));
	assert eqValSkips(RaiserOpcode.EqVal, raiserFloat(3.5), raiserFloat(3.5));
	assert !eqValSkips(RaiserOpcode.EqVal, raiserConstString("3"), raiserInt(3));
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

test "releasing the heaps leaves no register or global holding a string of the cleared heap" {
	const vm = createVM(makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 1, 1),
			raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),
			raiserABC(RaiserOpcode.Halt, 2, 0, 0),
		],
		[raiserConstString("ab"), raiserConstString("cd")]
	));
	execLoop(vm);
	assert vm.error == "", vm.error;
	assert vm.regs.slots[2] != 0 && handleHeapKind(vm.regs.slots[2]) == RaiserHeapKind.String;
	vmReleaseHeaps(vm);
	for (let i = 0; i < getModuleFunc(vm.mod, vm.mod.entry).frameSize; i += 1) {
		assert handleHeapKind(vm.regs.slots[i]) != RaiserHeapKind.String;
	}
	vm.ip = 0;
	vm.halted = false;
	execLoop(vm);
	assert vm.error == "", vm.error;
	assert vmText(vm, vm.exitValue) == "abcd";
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

test "the budget carries across an opcode that leaves the dispatch loop's fast path" {
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.LoadInt, 0, immField(7), 0),
		raiserABC(RaiserOpcode.Print, 0, 0, 0),
		raiserAx(RaiserOpcode.Jump, -2),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const vm = createVM(makeTestModule(code, []));
	vm.loopLimit = 5;
	execLoop(vm);
	assert vm.error.indexOf("too many iterations (limit 5)") >= 0, vm.error;
	assert vm.loopCount == 6;
	assert vm.output == "7\n7\n7\n7\n7\n7\n", vm.output;
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
	assert vm.error == "", vm.error;
	assert vm.loopCount == 3;
	assert vm.exitValue.intVal == 0;
}

// An opcode whose operands all name register 0 can name two classes for it; those take one register per operand.
function opcodeModule(i: int32, b: number, c: number): RaiserModule {
	return makeTestModule([raiserABC(i as RaiserOpcode, 0, b, c), raiserABC(RaiserOpcode.Halt, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], [raiserConstString("missingFn")]);
}

test "every opcode reaches a branch of the dispatch" {
	for (let i: int32 = 0; i <= (RaiserOpcode.MulU64 as int32); i += 1) {
		// a constant, a global and a copy plan give CallHost, LoadGlobal, StoreGlobal and CopyValue an operand to read
		let mod: RaiserModule;
		try {
			mod = opcodeModule(i, 0, 0);
		} catch (e) {
			mod = opcodeModule(i, 1, 2);
		}
		mod.globalCount = 1;
		mod.functions[0].copyPlans.push({ kind: RaiserCopyKind.Preserve, names: [], children: [], discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] });
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
	assert vm.error == "", vm.error;
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
	assert vm.error == "", vm.error;
	assert vm.exitValue.intVal == 42;
}

test "a host call leaves the active host heaps as it found them, none included" {
	_resetHostRegistryForTests();
	let during: RaiserArrayHeap | null = null;
	registerHostFn("peek", (args: RaiserValue[]): RaiserValue => {
		during = activeHostArrayHeap();
		return raiserInt(1);
	});
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	const consts: RaiserValue[] = [raiserConstString("peek")];
	setActiveHostHeaps(null, null);
	const vm = execModule(makeTestModule(code, consts));
	assert vm.error == "", vm.error;
	assert during == vm.arrayHeap;
	assert activeHostArrayHeap() == null;
	assert activeHostObjectHeap() == null;
	const outerArrays = createArrayHeap();
	const outerObjects = createStructHeap();
	setActiveHostHeaps(outerObjects, outerArrays);
	const again = execModule(makeTestModule(code, consts));
	assert during == again.arrayHeap;
	assert activeHostArrayHeap() == outerArrays;
	assert activeHostObjectHeap() == outerObjects;
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
	assert vm.error == "", vm.error;
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
			raiserABC(RaiserOpcode.LoadField, 1, 1, 2),
			raiserABC(RaiserOpcode.Print, 1, 0, 0),
			raiserABC(RaiserOpcode.Finally, 8, 0, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 1),
			raiserABC(RaiserOpcode.Print, 2, 0, 0),
			raiserABC(RaiserOpcode.FinallyEnd, 8, 0, 0),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserConstString("raise"), raiserConstString("finally"), raiserConstString("message")]
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
	assert vm.error == "", vm.error;
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
			raiserABC(RaiserOpcode.LoadField, 1, 1, 1),
			raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		],
		[raiserConstString("raise"), raiserConstString("message")]
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
	let last = "";
	for (let i = 0; i < 50000; i++) {
		const vm = execModule(mod);
		last = vmText(vm, vm.exitValue);
	}
	assert last.startsWith("minted "), last;
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
	assert vm.error == "", vm.error;
	assert vm.exitValue.intVal == 7;
}

test "CallHost site resolves its entry once and follows re-registration and reset" {
	_resetHostRegistryForTests();
	const fnA: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(1);
	const fnB: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(2);
	const fnC: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(3);
	registerHostFn("swap", fnA);
	const mod = makeTestModule([
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserConstString("swap")]);
	const func = getModuleFunc(mod, 0);
	assert func.hostCache[0] == null;
	const first = createVM(mod);
	execLoop(first);
	assert first.exitValue.intVal == 1;
	const cached = func.hostCache[0];
	assert cached != null;
	registerHostFn("swap", fnB);
	const second = createVM(mod);
	execLoop(second);
	assert second.exitValue.intVal == 2;
	assert func.hostCache[0] == cached;
	_resetHostRegistryForTests();
	const gone = createVM(mod);
	execLoop(gone);
	assert gone.error.indexOf("Unknown host function: swap", 0) >= 0, gone.error;
	registerHostFn("swap", fnC);
	const third = createVM(mod);
	execLoop(third);
	assert third.exitValue.intVal == 3;
	assert func.hostCache[0] != cached;
}

test "restricted CallHost refuses at a site an unrestricted run already cached" {
	_resetHostRegistryForTests();
	const fn: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(1);
	registerHostFn("unsafe", fn);
	const mod = makeTestModule([
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserConstString("unsafe")]);
	const open = createVM(mod);
	execLoop(open);
	assert open.error == "", open.error;
	assert getModuleFunc(mod, 0).hostCache[0] != null;
	const restricted = createVM(mod);
	restricted.hostCallsRestricted = true;
	restricted.hostPolicySource = "/cache/evil.ms";
	execLoop(restricted);
	assert restricted.error.indexOf("host function 'unsafe'", 0) >= 0, restricted.error;
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
	assert vm.error == "division by zero";
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
	assert f0.code[0].op == RaiserOpcode.CallDirect;
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
	const vm = createVM(mod);
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
	const vm = createVM(mod);
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
	const vm = createVM(createRaiserModule("reuse", [first, second], 0));
	const before = vmCallFunction(vm, 0, empty);
	assert before.kind == RaiserValueKind.Object;
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
	const vm = createVM(mod);
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
	const vm = createVM(createRaiserModule("t", funcs, 0));
	registerHostFn("reenter", (args: RaiserValue[]): RaiserValue => {
		const first = vmCallFunction(vm, 0, [raiserInt(args[0].intVal)]);
		const second = vmCallFunction(vm, 0, [raiserInt(args[0].intVal + 1)]);
		return raiserInt(first.intVal + second.intVal);
	});
	const r = vmCallFunction(vm, 1, [raiserInt(5)]);
	assert vm.error == "", vm.error;
	assert r.intVal == 218;
	assert vm.suspendedRuns.length == 0;
	assert vm.floor == 0 && vm.floor == 0;
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
	const vm = createVM(createRaiserModule("t", [addOne, addTwo, hosted, top], 0));
	registerHostFn("reenter", (args: RaiserValue[]): RaiserValue => {
		const first = vmCallFunction(vm, 1, [raiserInt(args[0].intVal)]);
		const second = vmCallFunction(vm, 1, [raiserInt(args[0].intVal + 1)]);
		return raiserInt(first.intVal + second.intVal);
	});
	const r = vmCallFunction(vm, 3, [raiserInt(5)]);
	assert vm.error == "", vm.error;
	assert r.intVal == 23;
	assert vm.callStack.depth == 0;
	assert vm.suspendedRuns.length == 0;
	assert vm.floor == 0 && vm.floor == 0;
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
	const vm = createVM(mod);
	vm.globals[0] = raiserInt(3);
	vmSpawnStrand(vm, 1);
	execLoop(vm);
	assert vm.error == "", vm.error;
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
	const vm = createVM(mod);
	vmSpawnStrand(vm, 1);
	execLoop(vm);

	// Control: the same main with no strand to switch to yields to itself.
	const vmAlone = createVM(mod);
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
	const vm = createVM(mod);
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
	const vm = createVM(mod);
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

test "a closure pair built by name is called through CallClosure with and without its env" {
	const mainCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.NewObject, 1, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 2, 0),
		raiserABC(RaiserOpcode.StoreField, 1, 1, 2),
		raiserABx(RaiserOpcode.LoadConst, 3, 2),
		raiserABC(RaiserOpcode.StoreField, 1, 3, 3),
		raiserABx(RaiserOpcode.LoadConst, 5, 4),
		raiserABC(RaiserOpcode.CallClosure, 4, 1, 2),
		raiserABC(RaiserOpcode.Print, 4, 0, 0),
		raiserABC(RaiserOpcode.NewObject, 7, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 2, 5),
		raiserABC(RaiserOpcode.StoreField, 7, 1, 2),
		raiserABC(RaiserOpcode.StoreField, 7, 3, 1),
		raiserABx(RaiserOpcode.LoadConst, 9, 6),
		raiserABC(RaiserOpcode.CallClosure, 8, 7, 2),
		raiserABC(RaiserOpcode.Print, 8, 0, 0),
		raiserABC(RaiserOpcode.Halt, 8, 0, 0),
	];
	const mainConsts: RaiserValue[] = [raiserInt(1), raiserConstString("fn"), raiserNil(), raiserConstString("env"), raiserInt(41), raiserInt(2), raiserInt(42)];
	const plusOne: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.AddI64Imm, 1, 0, immField(1)),
		raiserABC(RaiserOpcode.Ret, 1, 0, 0),
	];
	const viaEnv: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.LoadField, 2, 1, 0),
		raiserABC(RaiserOpcode.AddI64, 3, 0, 2),
		raiserABC(RaiserOpcode.Ret, 3, 0, 0),
	];
	const word = RaiserRegClass.Word;
	const ref = RaiserRegClass.Ref;
	const fMain = createRaiserFunction("main", mainCode, mainConsts, 0, 0, 11, [ref, ref, word, ref, word, word, ref, ref, word, word, ref]);
	const fPlusOne = createRaiserFunction("plusOne", plusOne, [], 1, 1, 2, [word, word]);
	const fViaEnv = createRaiserFunction("viaEnv", viaEnv, [raiserConstString("fn")], 2, 2, 4, [word, ref, word, word]);
	const vm = execModule(createRaiserModule("t", [fMain, fPlusOne, fViaEnv], 0));
	assert vm.error == "", vm.error;
	assert vm.output == "42\n43\n", vm.output;
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
	const vm = execModule(mod);
	assert vm.error == "", vm.error;
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
	const vm = execModule(mod);
	assert vm.error == "", vm.error;
	// The value survives being materialized twice — out of the strand that
	// built it, then out of the future's own storage into the reader.
	assert vm.output == "42\n";
	// One object per stage: the worker built it, the future owns a copy, and
	// main holds the closure it spawned plus the copy it read back.
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
	const vm = execModule(mod);
	assert vm.error == "", vm.error;
	// C would let the child write straight through the borrow; here the child
	// owns a copy, so the parent still reads what it stored (Amendment J).
	assert vm.output == "7\n";
	const childEnv = heapObjectGetField(vm.sched.strands.items[1].arrayHeap, vm.sched.strands.items[1].objectHeap, 0, "n");
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
	const vm = execModule(mod);
	assert vm.error == "", vm.error;
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
	const vm = execModule(mod);
	assert vm.error == "", vm.error;
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
	const vm = execModule(mod);
	assert vm.error == "", vm.error;
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
	const vm = execModule(mod);
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
	const vm = execModule(createRaiserModule("t", funcs, 0), false);
	assert vm.error == "", vm.error;
	assert vm.output == "1\n2\n";
	assert msMonoTimeMs() - before >= 20;
}

test "process.exit drops a pending timer" {
	const funcs: RaiserFunction[] = [yieldingMain(1), sleepingWorker(20)];
	const vm = execModule(createRaiserModule("t", funcs, 0), false);
	assert vm.error == "", vm.error;
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
	const workerConsts: RaiserValue[] = [raiserInt(5), raiserInt(2), raiserFuture(makeHandle(0, RaiserHeapKind.Future))];
	const funcs: RaiserFunction[] = [
		createRaiserFunction("main", mainCode, closurePairConsts(1), 0, 0, 8),
		createRaiserFunction("worker", workerCode, workerConsts, 0, 0, 6),
	];
	const vm = execModule(createRaiserModule("t", funcs, 0), false);
	assert vm.output == "2\n";
	assert vm.error == "";
	assert vm.unsettled;
	assert vm.exitValue.intVal == 13;
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
	assert vm.error == "", vm.error;
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
	assert vm.error == "", vm.error;
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
	const vm = execModule(createRaiserModule("t", funcs, 0));
	assert vm.error == "", vm.error;
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
	const vm = execModule(createRaiserModule("t", funcs, 0));
	assert vm.error == "", vm.error;
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
	const vm = execModule(createRaiserModule("t", funcs, 0));
	assert vm.error == "", vm.error;
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
	const vm = execModule(createRaiserModule("t", funcs, 0));
	assert vm.error == "", vm.error;
	assert vm.output == "boom\n", vm.output;
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
	const vm = execModule(createRaiserModule("t", funcs, 0));
	assert vm.error == "", vm.error;
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
	assert vm.error == "", vm.error;
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
	const vm = execModule(mod);
	assert vm.error == "compile-time-known-bad site";
	assert vm.halted;
}

test "an indirect call through an index outside the module fails loud" {
	const code: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABC(RaiserOpcode.CallIndirect, 2, 1, 0),
		raiserABC(RaiserOpcode.Halt, 2, 0, 0),
	];
	const consts: RaiserValue[] = [raiserInt(-1)];
	const f = createRaiserFunction("main", code, consts, 0, 0, 8);
	const funcs: RaiserFunction[] = [f];
	const mod = createRaiserModule("t", funcs, 0);
	const vm = execModule(mod);
	assert vm.error == "function index out of bounds: -1", vm.error;
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
	assert vm.error == "division by zero";
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
	assert vm.error == "division by zero";
	assert vmDumpStack(vm).endsWith("line 12 in main (current)");
}

test "a runtime error inside a direct callee reports the callee as the current frame" {
	const calleeCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.LoadConst, 0, 9999),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	calleeCode[0].line = 7;
	const callee = createRaiserFunction("boom", calleeCode, [raiserInt(0)], 0, 0, 1);
	const mainCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Call, 1, 0, 0),
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	];
	const main = createRaiserFunction("main", mainCode, [], 0, 0, 2);
	const funcs: RaiserFunction[] = [callee, main];
	const mod = createRaiserModule("test", funcs, 1);
	assert main.code[0].op == RaiserOpcode.CallDirect;
	const vm = execModule(mod);
	assert vm.error.indexOf("constant index out of bounds") >= 0, vm.error;
	assert vmDumpStack(vm).endsWith("line 7 in boom (current)"), vmDumpStack(vm);
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

const dropsEverything: RaiserInstruction[] = [
	raiserABx(RaiserOpcode.LoadConst, 0, 0),
	raiserABx(RaiserOpcode.LoadConst, 1, 1),
	raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),
	raiserABC(RaiserOpcode.Move, 4, 2, 0),
	raiserABC(RaiserOpcode.NewArray, 3, 1, 0),
	raiserABC(RaiserOpcode.NewObject, 5, 0, 0),
	raiserABC(RaiserOpcode.StoreField, 5, 2, 3),
	raiserABC(RaiserOpcode.Box, 6, 5, 0),
	raiserABx(RaiserOpcode.LoadConst, 7, 3),
	raiserABC(RaiserOpcode.Halt, 7, 0, 0),
];
const dropsEverythingConsts = [raiserConstString("ab"), raiserConstString("cd"), raiserConstString("f"), raiserInt(0)];


test "a packed Ret names the refs its frame owns and whether a handler can still be open there, before any module holds it" {
	const body = dropsEverything.slice(0, dropsEverything.length - 1);
	body.push(raiserABC(RaiserOpcode.Ret, 7, 0, 0));
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
	const worker = createRaiserFunction("worker", body, dropsEverythingConsts, 0, 0, 8);
	const guarded = createRaiserFunction("guarded", guardedCode, [raiserInt(7)], 0, 0, 4);
	const owned = worker.ownRefs.length;
	const ret = worker.packed[worker.packed.length - 1];
	assert owned > 0 && packedB(ret) == worker.arity && ((ret >> 40) & 65535) == owned * 2, `${packedB(ret)} ${(ret >> 40) & 65535} ${owned}`;
	for (let pc = 0; pc < guarded.code.length; pc += 1) {
		if (guarded.code[pc].op == RaiserOpcode.Ret) assert ((guarded.packed[pc] >> 40) & 1) == 1;
	}
}

test "Unbox with the payload flag reads the word of any boxed kind" {
	const vm = execModule(classedModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABx(RaiserOpcode.LoadConst, 1, 0), raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),
			raiserABC(RaiserOpcode.Box, 3, 2, 0), raiserABC(RaiserOpcode.Unbox, 4, 3, 1), raiserABC(RaiserOpcode.LoadNil, 5, 0, 0),
			raiserABC(RaiserOpcode.Unbox, 6, 5, 1), raiserABC(RaiserOpcode.Halt, 4, 0, 0),
		],
		[raiserConstString("ab")],
		[RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Dyn, RaiserRegClass.Word, RaiserRegClass.Dyn, RaiserRegClass.Word]
	));
	assert vm.error == "", vm.error;
	assert vm.exitValue.kind == RaiserValueKind.Int && vm.exitValue.intVal == vm.regs.slots[2];
	assert vm.regs.slots[6] == 0;
}

// A callee of `argc` parameters whose class, Word or Ref, follows bit i of `pattern`, and the
// value it returns: ten times each word argument's position plus the length of each ref argument.
function windowCallee(pattern: int32, argc: int32): RaiserFunction {
	const classes: RaiserRegClass[] = [];
	for (let i = 0; i < argc; i += 1) classes.push(((pattern >> i) & 1) == 1 ? RaiserRegClass.Ref : RaiserRegClass.Word);
	classes.push(RaiserRegClass.Word);
	classes.push(RaiserRegClass.Word);
	const acc = argc;
	const tmp = argc + 1;
	const code: RaiserInstruction[] = [raiserABC(RaiserOpcode.LoadInt, acc, immField(0), 0)];
	for (let i = 0; i < argc; i += 1) {
		if (((pattern >> i) & 1) == 1) {
			code.push(raiserABC(RaiserOpcode.StrLen, tmp, i, 0));
			code.push(raiserABC(RaiserOpcode.AddI64, acc, acc, tmp));
		} else {
			code.push(raiserABC(RaiserOpcode.AddI64, acc, acc, i));
		}
	}
	code.push(raiserABC(RaiserOpcode.Ret, acc, 0, 0));
	return createRaiserFunction("window", code, [], argc, argc, argc + 2, classes);
}

function windowExpected(pattern: int32, argc: int32): int64 {
	let total: int64 = 0;
	for (let i = 0; i < argc; i += 1) total += ((pattern >> i) & 1) == 1 ? (i + 1) : (i + 1) * 10;
	return total;
}

// The caller puts argument i in R[1 + i]: a word holding (i + 1) * 10, or a string of i + 1 characters.
function windowCaller(pattern: int32, argc: int32, indirect: boolean): RaiserFunction {
	const classes: RaiserRegClass[] = [RaiserRegClass.Word];
	const consts: RaiserValue[] = [];
	const code: RaiserInstruction[] = [];
	for (let i = 0; i < argc; i += 1) {
		if (((pattern >> i) & 1) == 1) {
			classes.push(RaiserRegClass.Ref);
			let text = "";
			for (let k = 0; k <= i; k += 1) text = text + "x";
			consts.push(raiserConstString(text));
			code.push(raiserABx(RaiserOpcode.LoadConst, 1 + i, consts.length - 1));
		} else {
			classes.push(RaiserRegClass.Word);
			code.push(raiserABC(RaiserOpcode.LoadInt, 1 + i, immField((i + 1) * 10), 0));
		}
	}
	classes.push(RaiserRegClass.Word);
	if (indirect) {
		code.push(raiserABC(RaiserOpcode.LoadInt, argc + 1, immField(1), 0));
		code.push(raiserABC(RaiserOpcode.CallIndirect, 0, argc + 1, argc));
	} else {
		code.push(raiserABC(RaiserOpcode.Call, 0, 1, argc));
	}
	code.push(raiserABC(RaiserOpcode.Halt, 0, 0, 0));
	return createRaiserFunction("caller", code, consts, 0, 0, argc + 2, classes);
}

test "word and ref arguments in every order reach their parameters through Call and CallIndirect" {
	for (let argc = 0; argc <= 6; argc += 1) {
		for (let pattern = 0; pattern < (1 << argc); pattern += 1) {
			for (const indirect of [false, true]) {
				const funcs: RaiserFunction[] = [windowCaller(pattern, argc, indirect), windowCallee(pattern, argc)];
				const vm = execModule(createRaiserModule("window", funcs, 0));
				assert vm.error == "", `argc ${argc} pattern ${pattern} indirect ${indirect}: ${vm.error}`;
				assert vm.exitValue.intVal == windowExpected(pattern, argc), `argc ${argc} pattern ${pattern} indirect ${indirect}: ${vm.exitValue.intVal}`;
			}
		}
	}
}

test "a callee's word registers leave no word in the slots a caller holds handles in" {
	const word = RaiserRegClass.Word;
	const main = createRaiserFunction("main", [raiserABC(RaiserOpcode.Call, 0, 1, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], [], 0, 0, 2, [word, word]);
	const mid = createRaiserFunction("mid", [raiserABC(RaiserOpcode.Call, 0, 2, 0), raiserABC(RaiserOpcode.LoadInt, 3, immField(5), 0), raiserABC(RaiserOpcode.Ret, 3, 0, 0)], [], 0, 0, 4, [word, RaiserRegClass.Ref, word, word]);
	const leaf = createRaiserFunction("leaf", [raiserABC(RaiserOpcode.LoadInt, 0, immField(30), 0), raiserABC(RaiserOpcode.LoadInt, 1, immField(30), 0), raiserABC(RaiserOpcode.Ret, 0, 0, 0)], [], 0, 0, 2, [word, word]);
	const vm = execModule(createRaiserModule("leftover", [main, mid, leaf], 0));
	assert vm.error == "" && vm.exitValue.intVal == 5, vm.error;
	assert vm.regs.slots[2] == 0, `mid keeps ${vm.regs.slots[2]} in its Ref register`;
}

// A spawned strand runs in a frame of its own whose first register is the environment slot, whatever
// order the rest of its registers take.
test "a spawned strand keeps its word and ref registers apart in every order" {
	for (let argc = 0; argc <= 5; argc += 1) {
		for (let pattern = 0; pattern < (1 << argc); pattern += 1) {
			const classes: RaiserRegClass[] = [RaiserRegClass.Ref];
			const workerConsts: RaiserValue[] = [];
			const workerCode: RaiserInstruction[] = [];
			for (let i = 0; i < argc; i += 1) {
				const ref = ((pattern >> i) & 1) == 1;
				classes.push(ref ? RaiserRegClass.Ref : RaiserRegClass.Word);
				if (ref) {
					workerConsts.push(raiserConstString("xy"));
					workerCode.push(raiserABx(RaiserOpcode.LoadConst, 1 + i, workerConsts.length - 1));
				} else {
					workerCode.push(raiserABC(RaiserOpcode.LoadInt, 1 + i, immField(10), 0));
				}
			}
			classes.push(RaiserRegClass.Word);
			classes.push(RaiserRegClass.Word);
			const acc = argc + 1;
			const tmp = argc + 2;
			workerCode.push(raiserABC(RaiserOpcode.LoadInt, acc, immField(0), 0));
			let expected: int64 = 0;
			for (let i = 0; i < argc; i += 1) {
				if (((pattern >> i) & 1) == 1) {
					workerCode.push(raiserABC(RaiserOpcode.StrLen, tmp, 1 + i, 0));
					workerCode.push(raiserABC(RaiserOpcode.AddI64, acc, acc, tmp));
					expected += 2;
				} else {
					workerCode.push(raiserABC(RaiserOpcode.AddI64, acc, acc, 1 + i));
					expected += 10;
				}
			}
			workerCode.push(raiserABC(RaiserOpcode.Ret, acc, 0, 0));
			const worker = createRaiserFunction("worker", workerCode, workerConsts, 0, 0, argc + 3, classes);
			const mainCode = closurePairCode();
			mainCode.push(raiserABC(RaiserOpcode.Spawn, 3, 1, 0));
			mainCode.push(raiserABC(RaiserOpcode.Await, 4, 3, 0));
			mainCode.push(raiserABC(RaiserOpcode.Halt, 4, 0, 0));
			const mainFn = createRaiserFunction("main", mainCode, closurePairConsts(1), 0, 0, 8);
			const funcs: RaiserFunction[] = [mainFn, worker];
			const vm = execModule(createRaiserModule("spawnWindow", funcs, 0));
			assert vm.error == "", `argc ${argc} pattern ${pattern}: ${vm.error}`;
			assert vm.exitValue.intVal == expected, `argc ${argc} pattern ${pattern}: ${vm.exitValue.intVal}`;
		}
	}
}

// --- Placed mode: the bytecode carries every count ---

function slotted(inst: RaiserInstruction, slot: number): RaiserInstruction {
	inst.slot = slot;
	return inst;
}

function vmLiveCount(vm: RaiserVM): number {
	return (vm.objectHeap.objects.length - vm.objectHeap.freeList.length)
		+ heapSeqHandles(vm.arrayHeap).length + heapObjectCellHandles(vm.arrayHeap).length;
}

function objectRcAt(vm: RaiserVM, k: number): number {
	const cells = heapObjectCellHandles(vm.arrayHeap);
	cells.sort((a: int64, b: int64): number => (a < b ? -1 : a > b ? 1 : 0));
	if (cells.length > k) return rcCountOf(vm.arrayHeap, vm.objectHeap, cells[k]);
	return vm.objectHeap.objects[k].rc;
}

function fieldNames(names: string[]): RaiserValue[] {
	const out: RaiserValue[] = [];
	for (const name of names) out.push(raiserConstString(name));
	return out;
}

function mainWithClasses(code: RaiserInstruction[], classes: RaiserRegClass[], types: RaiserClassType[], names: string[]): RaiserFunction {
	const main = createRaiserFunction("main", code, fieldNames(names), 0, 0, classes.length, classes);
	main.classTypes = types;
	return main;
}

const nodeClass: RaiserRegClass[] = [RaiserRegClass.Ref];

test "placed: RcInc and RcDec that balance free a nested object chain and leave nothing live" {
	const node = createClassType("Node", -1, [], ["next"], nodeClass);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		raiserABC(RaiserOpcode.RcInc, 1, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 0, 1), 0),
		raiserABC(RaiserOpcode.RcDec, 1, 0, 0),
		raiserABC(RaiserOpcode.RcDec, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [node], ["next"]);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vmLiveCount(vm) == 0, `${vmLiveCount(vm)}`;
	assert ledgerAudit(vm.arrayHeap, vm.objectHeap, [], "program") == "";
}

test "placed: a program that allocates and halts without its RcDec fails the ledger audit unless it runs compile-time" {
	const node = createClassType("Node", -1, [], ["next"], nodeClass);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref], [node], ["next"]);
	const audited = execModule(createRaiserModule("placed", [main], 0), false);
	assert audited.error.indexOf("object items live after program end") >= 0, audited.error;
	const unaudited = execModule(createRaiserModule("placed", [main], 0), true);
	assert unaudited.error == "", unaudited.error;
	const declined = createVM(createRaiserModule("placed", [main], 0), false);
	declined.auditLedger = false;
	execLoop(declined);
	assert declined.error == "", declined.error;
}

test "placed: the last RcDec of an array releases its elements and frees the array and the element" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		slotted(raiserABC(RaiserOpcode.NewArray, 0, 0, 0), arrayClassSlot(RaiserRegClass.Ref)),
		raiserABC(RaiserOpcode.RcInc, 1, 0, 0),
		raiserABC(RaiserOpcode.ArrayPush, 0, 1, 0),
		raiserABC(RaiserOpcode.RcDec, 1, 0, 0),
		raiserABC(RaiserOpcode.RcDec, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [leaf], []);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vmLiveCount(vm) == 0, `${vmLiveCount(vm)}`;
}

test "placed: the last RcDec of an array of uncounted elements leaves the elements to their owner" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		slotted(raiserABC(RaiserOpcode.NewArray, 0, 0, 0), arrayClassSlot(RaiserRegClass.Ref, false, true)),
		raiserABC(RaiserOpcode.ArrayPush, 0, 1, 0),
		raiserABC(RaiserOpcode.RcDec, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [leaf], []);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert objectRcAt(vm, 0) == 1 && vmLiveCount(vm) == 1, `${objectRcAt(vm, 0)} ${vmLiveCount(vm)}`;
}

test "placed: a class's destroy routine runs once on the last RcDec, sees the cell's fields, and the VM frees the cell after it returns" {
	const cell = createClassType("Cell", -1, [], ["n", "child"], [RaiserRegClass.Word, RaiserRegClass.Ref]);
	const leaf = createClassType("Leaf", -1, [], [], []);
	cell.destroyFn = 1;
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 2, 0),
		raiserABC(RaiserOpcode.LoadInt, 2, immField(7), 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 0, 2), 0),
		raiserABC(RaiserOpcode.RcInc, 1, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 1, 1), 1),
		raiserABC(RaiserOpcode.RcDec, 1, 0, 0),
		raiserABC(RaiserOpcode.RcDec, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Word], [cell, leaf], ["n", "child"]);
	const destroy = createRaiserFunction("destroy", [
		slotted(raiserABC(RaiserOpcode.LoadSlot, 1, 0, 0), 0),
		raiserABC(RaiserOpcode.Print, 1, 0, 0),
		slotted(raiserABC(RaiserOpcode.LoadSlot, 2, 0, 1), 1),
		raiserABC(RaiserOpcode.RcDec, 2, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	], fieldNames(["n", "child"]), 1, 1, 3, [RaiserRegClass.Ref, RaiserRegClass.Word, RaiserRegClass.Ref]);
	const vm = execModule(createRaiserModule("placed", [main, destroy], 0));
	assert vm.error == "", vm.error;
	assert vm.output == "7\n", vm.output;
	assert vmLiveCount(vm) == 0 && vm.disposing.length == 0 && vm.dropped.length == 0, `${vmLiveCount(vm)}`;
}

function chainMain(node: RaiserClassType): RaiserFunction {
	return mainWithClasses([
		raiserABC(RaiserOpcode.LoadInt, 2, immField(0), 0),
		raiserABC(RaiserOpcode.LoadInt, 3, immField(3000), 0),
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 1, 0, 0), 0),
		raiserABC(RaiserOpcode.Move, 0, 1, 0),
		raiserABC(RaiserOpcode.AddI64Imm, 2, 2, immField(1)),
		raiserABC(RaiserOpcode.BrLtI64, 2, 3, branchField(-5)),
		raiserABC(RaiserOpcode.RcDec, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Word, RaiserRegClass.Word], [node], ["next"]);
}

test "placed: a chain longer than the frame stack destroys through routine frames without overflowing it" {
	const node = createClassType("Node", -1, [], ["next"], nodeClass);
	node.destroyFn = 1;
	const destroy = createRaiserFunction("destroy", [
		slotted(raiserABC(RaiserOpcode.LoadSlot, 1, 0, 0), 0),
		raiserABC(RaiserOpcode.RcDec, 1, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	], fieldNames(["next"]), 1, 1, 2, [RaiserRegClass.Ref, RaiserRegClass.Ref]);
	const vm = execModule(createRaiserModule("placed", [chainMain(node), destroy], 0));
	assert vm.error == "", vm.error;
	assert vmLiveCount(vm) == 0, `${vmLiveCount(vm)}`;
}

test "placed: a chain of classes without a routine is walked past the host-stack bound and freed" {
	const node = createClassType("Node", -1, [], ["next"], nodeClass);
	const vm = execModule(createRaiserModule("placed", [chainMain(node)], 0));
	assert vm.error == "", vm.error;
	assert vmLiveCount(vm) == 0 && vm.dropped.length == 0, `${vmLiveCount(vm)}`;
}

function storeSequence(viaArray: boolean): RaiserVM {
	const pair = createClassType("Pair", -1, [], ["a"], nodeClass);
	const code = viaArray
		? [
			raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
			slotted(raiserABC(RaiserOpcode.NewArray, 0, 0, 0), arrayClassSlot(RaiserRegClass.Ref)),
			raiserABC(RaiserOpcode.ArrayPush, 0, 1, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		]
		: [
			raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
			raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
			slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 0, 1), 0),
			raiserABC(RaiserOpcode.Move, 2, 1, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		];
	const main = mainWithClasses(code, [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref], [pair], ["a"]);
	const vm = createVM(createRaiserModule("placed", [main], 0));
	execLoop(vm);
	return vm;
}

test "placed: stores and moves leave every count where it was" {
	const vm = storeSequence(false);
	assert objectRcAt(vm, 0) == 1 && objectRcAt(vm, 1) == 1, `${objectRcAt(vm, 1)}`;
}

test "placed: an array push counts nothing" {
	const vm = storeSequence(true);
	assert objectRcAt(vm, 0) == 1 && heapArrayRc(vm.arrayHeap, heapSeqHandles(vm.arrayHeap)[0]) == 1;
}

function copyPlan(kind: RaiserCopyKind, names: string[], children: int32[]): RaiserCopyPlan {
	return { kind, names, children, discriminants: [], laid: RAISER_NO_CLASS, laidChildren: [] };
}

test "placed: DestroyValue by plan frees an owned nested aggregate and releases a shared reference once" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const inner = createClassType("Inner", -1, [], ["leaf"], nodeClass);
	const outer = createClassType("Outer", -1, [], ["inner"], nodeClass);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 2, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 2, 0),
		raiserABC(RaiserOpcode.RcInc, 2, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 1, 0, 2), 0),
		raiserABC(RaiserOpcode.NewObject, 0, 3, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 1, 1), 0),
		raiserABC(RaiserOpcode.WasMoved, 1, 0, 0),
		raiserABC(RaiserOpcode.DestroyValue, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref], [leaf, inner, outer], ["leaf", "inner"]);
	main.copyPlans = [copyPlan(RaiserCopyKind.Object, ["inner"], [1]), copyPlan(RaiserCopyKind.Object, [], [])];
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vmLiveCount(vm) == 1 && objectRcAt(vm, 0) == 1 && vm.regs.slots[0] == 0, `${vmLiveCount(vm)} ${objectRcAt(vm, 0)}`;
}

test "placed: DestroyValue by an array plan frees the array and every aggregate element" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		slotted(raiserABC(RaiserOpcode.NewArray, 0, 0, 0), arrayClassSlot(RaiserRegClass.Ref)),
		raiserABC(RaiserOpcode.ArrayPush, 0, 1, 0),
		raiserABC(RaiserOpcode.WasMoved, 1, 0, 0),
		raiserABC(RaiserOpcode.DestroyValue, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [leaf], []);
	main.copyPlans = [copyPlan(RaiserCopyKind.Array, [], [1]), copyPlan(RaiserCopyKind.Object, [], [])];
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vmLiveCount(vm) == 0, `${vmLiveCount(vm)}`;
}

test "placed: SinkValue destroys the old aggregate and takes the source, and a destination that already holds it stays" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		raiserABC(RaiserOpcode.SinkValue, 0, 1, 0),
		raiserABC(RaiserOpcode.SinkValue, 0, 1, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [leaf], []);
	main.copyPlans = [copyPlan(RaiserCopyKind.Object, [], [])];
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vm.regs.slots[0] == vm.regs.slots[1] && vmLiveCount(vm) == 1 && rcCountOf(vm.arrayHeap, vm.objectHeap, vm.regs.slots[0]) == 1, `${vmLiveCount(vm)}`;
}

test "placed: CopyValue counts an alias and leaves a fresh copy with its allocation count" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.CopyValue, 1, 0, 0),
		raiserABC(RaiserOpcode.CopyValue, 2, 0, 1),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref], [leaf], []);
	main.copyPlans = [copyPlan(RaiserCopyKind.Preserve, [], []), copyPlan(RaiserCopyKind.Object, [], [])];
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vm.regs.slots[1] == vm.regs.slots[0] && vm.regs.slots[2] != vm.regs.slots[0], `${vm.regs.slots[0]} ${vm.regs.slots[2]}`;
	assert objectRcAt(vm, 0) == 2 && objectRcAt(vm, 1) == 1, `${objectRcAt(vm, 0)} ${objectRcAt(vm, 1)}`;
}

function cyclicRelease(cyclic: boolean, viaRcDec: boolean): RaiserVM {
	const node = createClassType("Node", -1, [], ["next"], nodeClass);
	node.cyclic[0] = cyclic;
	const release = viaRcDec
		? [raiserABC(RaiserOpcode.RcInc, 0, 0, 0), raiserABC(RaiserOpcode.RcDec, 0, 1, 0)]
		: [raiserABC(RaiserOpcode.RcDec, 0, 0, 0)];
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		raiserABC(RaiserOpcode.RcInc, 1, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 0, 1), 0),
		...release,
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [node], ["next"]);
	return execModule(createRaiserModule("placed", [main], 0));
}

function cyclicRoots(cyclic: boolean, viaRcDec: boolean): number {
	const vm = cyclicRelease(cyclic, viaRcDec);
	return vm.error == "" ? vm.arrayHeap.orcRoots.length : -1;
}

test "placed: a release that leaves a cyclic referent alive registers it with the cycle collector" {
	assert cyclicRoots(false, false) == 0;
	assert cyclicRoots(true, false) == 1;
	assert cyclicRoots(true, true) == 1;
}

function garbageCycle(): RaiserVM {
	const node = createClassType("Node", -1, [], ["next"], nodeClass);
	node.cyclic[0] = true;
	node.destroyFn = 1;
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		raiserABC(RaiserOpcode.RcInc, 1, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 0, 1), 0),
		raiserABC(RaiserOpcode.RcInc, 0, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 1, 0, 0), 0),
		raiserABC(RaiserOpcode.RcDec, 1, 0, 0),
		raiserABC(RaiserOpcode.RcDec, 0, 1, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [node], ["next"]);
	const destroy = createRaiserFunction("destroy", [
		raiserABC(RaiserOpcode.LoadInt, 1, immField(1), 0),
		raiserABC(RaiserOpcode.Print, 1, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	], [], 1, 1, 2, [RaiserRegClass.Ref, RaiserRegClass.Word]);
	const vm = createVM(createRaiserModule("placed", [main, destroy], 0));
	vm.arrayHeap.orcThreshold = -ORC_DEFAULT_THRESHOLD;
	execLoop(vm);
	return vm;
}

test "placed: a garbage cycle is freed by the collector, each cell's destroy routine runs once" {
	const vm = garbageCycle();
	assert vm.error == "", vm.error;
	assert vm.output == "1\n1\n", vm.output;
	assert vmLiveCount(vm) == 0 && vm.arrayHeap.orcRoots.length == 0, `${vmLiveCount(vm)}`;
	assert vm.dropped.length == 0 && vm.disposing.length == 0;
}

function garbageCycleBelowThreshold(comptime: boolean): RaiserVM {
	const node = createClassType("Node", -1, [], ["next"], nodeClass);
	node.cyclic[0] = true;
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		raiserABC(RaiserOpcode.RcInc, 1, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 0, 1), 0),
		raiserABC(RaiserOpcode.RcInc, 0, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 1, 0, 0), 0),
		raiserABC(RaiserOpcode.RcDec, 1, 0, 0),
		raiserABC(RaiserOpcode.RcDec, 0, 1, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [node], ["next"]);
	return execModule(createRaiserModule("placed", [main], 0), comptime);
}

test "placed: a garbage cycle below the threshold is collected only by the ledger build's exit collect" {
	const audited = garbageCycleBelowThreshold(false);
	assert audited.error == "", audited.error;
	assert vmLiveCount(audited) == 0 && audited.arrayHeap.orcRoots.length == 0, `${vmLiveCount(audited)}`;
	const comptime = garbageCycleBelowThreshold(true);
	assert comptime.error == "", comptime.error;
	assert vmLiveCount(comptime) == 2 && comptime.arrayHeap.orcRoots.length > 0, `${vmLiveCount(comptime)}`;
}

test "placed: a cycle a register still holds is kept by the collector" {
	const vm = garbageCycleHeld();
	assert vm.error == "", vm.error;
	assert vm.output == "" && vmLiveCount(vm) == 2 && vm.arrayHeap.orcRoots.length == 0, `${vm.output} ${vmLiveCount(vm)}`;
}

function garbageCycleHeld(): RaiserVM {
	const node = createClassType("Node", -1, [], ["next"], nodeClass);
	node.cyclic[0] = true;
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		raiserABC(RaiserOpcode.RcInc, 1, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 0, 1), 0),
		raiserABC(RaiserOpcode.RcInc, 0, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 1, 0, 0), 0),
		raiserABC(RaiserOpcode.RcDec, 1, 1, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [node], ["next"]);
	const vm = createVM(createRaiserModule("placed", [main], 0));
	vm.arrayHeap.orcThreshold = -ORC_DEFAULT_THRESHOLD;
	execLoop(vm);
	return vm;
}

test "placed: 300 registered candidates trip the threshold once, then keep counting" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const code: RaiserInstruction[] = [];
	for (let i = 0; i < 300; i += 1) {
		code.push(raiserABC(RaiserOpcode.NewObject, 0, 1, 0));
		code.push(raiserABC(RaiserOpcode.RcInc, 0, 0, 0));
		code.push(raiserABC(RaiserOpcode.RcDec, 0, 1, 0));
	}
	code.push(raiserABC(RaiserOpcode.Halt, 0, 0, 0));
	const main = mainWithClasses(code, [RaiserRegClass.Ref], [leaf], []);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vm.arrayHeap.orcRoots.length == 300 - 2 * ORC_DEFAULT_THRESHOLD, `${vm.arrayHeap.orcRoots.length}`;
}

function keptRoutine(keep: boolean): RaiserVM {
	const cell = createClassType("Cell", -1, [], [], []);
	cell.destroyFn = 1;
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.RcDec, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref], [cell], []);
	const body = [raiserABC(RaiserOpcode.RcHeld, 0, 1, 0)];
	if (keep) body.push(raiserABC(RaiserOpcode.RcInc, 0, 0, 0));
	body.push(raiserABC(RaiserOpcode.RcKeptCheck, 0, 1, 0));
	body.push(raiserABC(RaiserOpcode.Ret, 0, 0, 0));
	const destroy = createRaiserFunction("destroy", body, [], 1, 1, 2, [RaiserRegClass.Ref, RaiserRegClass.Word]);
	return execModule(createRaiserModule("placed", [main, destroy], 0));
}

test "placed: RcKeptCheck passes a destroy routine that kept nothing and fails one that kept its own cell" {
	const clean = keptRoutine(false);
	assert clean.error == "" && vmLiveCount(clean) == 0, clean.error;
	const kept = keptRoutine(true);
	assert kept.error.includes("onDestroy kept a reference to the Cell it destroys"), kept.error;
}

test "WasMoved clears a word register to 0 and a ref register to nil without touching a count" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.LoadInt, 1, immField(5), 0),
		raiserABC(RaiserOpcode.WasMoved, 1, 0, 0),
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.WasMoved, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Word], [leaf], []);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vm.regs.slots[0] == 0 && vm.regs.slots[1] == 0 && objectRcAt(vm, 0) == 1;
}

function throwingDestroy(): RaiserVM {
	const cell = createClassType("Cell", -1, [], [], []);
	cell.destroyFn = 1;
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.RcDec, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref], [cell], []);
	const destroy = createRaiserFunction("destroy", [
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABC(RaiserOpcode.Throw, 1, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	], fieldNames(["boom"]), 1, 1, 2, [RaiserRegClass.Ref, RaiserRegClass.Ref]);
	return execModule(createRaiserModule("placed", [main, destroy], 0));
}

test "placed: an exception thrown by a destroy routine unwinds its frame and still frees the cell" {
	let escaped = "";
	try { throwingDestroy(); } catch (e) { escaped = e.message; }
	assert escaped == "", escaped;
	const vm = throwingDestroy();
	assert vm.error.includes("boom"), vm.error;
	assert vm.disposing.length == 0 && vmLiveCount(vm) == 0 && vm.callStack.depth == 0, `${vm.disposing.length} ${vmLiveCount(vm)} ${vm.callStack.depth}`;
}

// --- Array kernels: results the C kernels give, and the counts they keep ---

function kernelVM(classes: RaiserRegClass[], code: RaiserInstruction[], consts: RaiserValue[]): RaiserVM {
	const main = createRaiserFunction("main", code, consts, 0, 0, classes.length, classes);
	return createVM(createRaiserModule("placed", [main], 0));
}

function heldText(vm: RaiserVM, handle: int64): string {
	let text = "[";
	const n = heapArrayLen(vm.arrayHeap, handle);
	for (let i = 0; i < n; i += 1) {
		if (i > 0) text = `${text},`;
		text = `${text}${raiserToString(vm.arrayHeap, heapArrayGet(vm.arrayHeap, handle, i))}`;
	}
	return `${text}]`;
}

function numberArray(vm: RaiserVM, values: number[]): int64 {
	const handle = heapAllocArrayOf(vm.arrayHeap, RaiserRegClass.Float);
	for (const v of values) heapArrayPush(vm.arrayHeap, handle, raiserFloat(v));
	return handle;
}

function ownedString(vm: RaiserVM, text: string): RaiserValue {
	return heapAllocString(vm.arrayHeap, text);
}

function ownedObject(vm: RaiserVM): RaiserValue {
	return raiserObject(heapAllocObject(vm.objectHeap));
}

function refArray(vm: RaiserVM, elems: RaiserValue[]): int64 {
	const handle = heapAllocArrayOf(vm.arrayHeap, RaiserRegClass.Ref);
	for (const e of elems) heapArrayPush(vm.arrayHeap, handle, e);
	return handle;
}

function stringRc(vm: RaiserVM, v: RaiserValue): int32 {
	return stringHandleRc(v.intVal) as int32;
}

function objectRc(vm: RaiserVM, v: RaiserValue): int32 {
	return rcCountOf(vm.arrayHeap, vm.objectHeap, v.intVal);
}

function numberSplice(values: number[], start: number, count: number, withItem: boolean, item: number): string {
	const vm = kernelVM([RaiserRegClass.Ref, RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Float], [
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABx(RaiserOpcode.LoadConst, 2, 1),
		raiserABx(RaiserOpcode.LoadConst, 3, 2),
		withItem ? raiserABC(RaiserOpcode.ArraySplice3, 0, 3, 1) : raiserABC(RaiserOpcode.ArraySplice, 0, 0, 1),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserInt(start as int64), raiserInt(count as int64), raiserFloat(item)]);
	vm.regs.slots[0] = numberArray(vm, values);
	execLoop(vm);
	if (vm.error != "") return vm.error;
	return heldText(vm, vm.regs.slots[0]);
}

test "array kernels: splice removes by the C clamps and splice3 inserts where the removal began" {
	const base: number[] = [5, 4, 3, 1];
	assert numberSplice(base, 1, 2, false, 0) == "[5,1]";
	assert numberSplice(base, -1, 1, false, 0) == "[5,4,3,1]";
	assert numberSplice(base, 9, 1, false, 0) == "[5,4,3,1]";
	assert numberSplice(base, 0, 0, false, 0) == "[5,4,3,1]";
	assert numberSplice(base, 0, -3, false, 0) == "[5,4,3,1]";
	assert numberSplice(base, 2, 99, false, 0) == "[5,4]";
	assert numberSplice(base, 0, 99, false, 0) == "[]";
	assert numberSplice([5, 1], -4, 0, true, 7) == "[7,5,1]";
	assert numberSplice([5, 1], 99, 0, true, 7) == "[5,1,7]";
	assert numberSplice([5, 1], 1, 1, true, 7) == "[5,7]";
	assert numberSplice([5, 1], 0, 99, true, 7) == "[7]";
	assert numberSplice([5, 1], 1, 0, true, 7) == "[5,7,1]";
	assert numberSplice([], 3, 2, true, 7) == "[7]";
}

function numberTransform(values: number[], op: RaiserOpcode): string {
	const vm = kernelVM([RaiserRegClass.Ref], [raiserABC(op, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], []);
	vm.regs.slots[0] = numberArray(vm, values);
	execLoop(vm);
	if (vm.error != "") return vm.error;
	return heldText(vm, vm.regs.slots[0]);
}

test "array kernels: reverse and sort rewrite a number array in place" {
	assert numberTransform([5, 3, 5, 1, 4, 1], RaiserOpcode.ArraySort) == "[1,1,3,4,5,5]";
	assert numberTransform([5, 3, 4], RaiserOpcode.ArrayReverse) == "[4,3,5]";
	assert numberTransform([], RaiserOpcode.ArraySort) == "[]";
	assert numberTransform([2], RaiserOpcode.ArrayReverse) == "[2]";
	assert numberTransform([-1.5, 2, -7, 0], RaiserOpcode.ArraySort) == "[-7,-1.5,0,2]";
}

function numberFill(values: number[], value: number): string {
	const vm = kernelVM([RaiserRegClass.Ref, RaiserRegClass.Float], [
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABC(RaiserOpcode.ArrayFill, 0, 1, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserFloat(value)]);
	vm.regs.slots[0] = numberArray(vm, values);
	execLoop(vm);
	if (vm.error != "") return vm.error;
	return heldText(vm, vm.regs.slots[0]);
}

function numberCopy(values: number[], other: number[], op: RaiserOpcode, start: number, end: number): string {
	const vm = kernelVM([RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Ref], [
		raiserABx(RaiserOpcode.LoadConst, 2, 0),
		raiserABx(RaiserOpcode.LoadConst, 3, 1),
		op == RaiserOpcode.ArrayConcat ? raiserABC(op, 1, 0, 4) : raiserABC(op, 1, 0, 2),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserInt(start as int64), raiserInt(end as int64)]);
	vm.regs.slots[0] = numberArray(vm, values);
	vm.regs.slots[4] = numberArray(vm, other);
	execLoop(vm);
	if (vm.error != "") return vm.error;
	if (vm.regs.slots[1] == vm.regs.slots[0] || vm.regs.slots[1] == vm.regs.slots[4]) return "result aliases an operand";
	return heldText(vm, vm.regs.slots[1]);
}

test "array kernels: fill, slice and concat of a number array follow the C kernels" {
	assert numberFill([5, 4, 3], 2) == "[2,2,2]";
	assert numberFill([], 2) == "[]";
	const six: number[] = [6, 1, 8, 7, 9, 3];
	assert numberCopy(six, [], RaiserOpcode.ArraySliceCopy, 1, 3) == "[1,8]";
	assert numberCopy(six, [], RaiserOpcode.ArraySliceCopy, 1, -1) == "[1,8,7,9]";
	assert numberCopy(six, [], RaiserOpcode.ArraySliceCopy, -2, 9007199254740991) == "[9,3]";
	assert numberCopy(six, [], RaiserOpcode.ArraySliceCopy, 4, 2) == "[]";
	assert numberCopy(six, [], RaiserOpcode.ArraySliceCopy, -99, 99) == "[6,1,8,7,9,3]";
	assert numberCopy(six, [], RaiserOpcode.ArraySliceCopy, 2, 2) == "[]";
	assert numberCopy([7, 6], [0, 0], RaiserOpcode.ArrayConcat, 0, 0) == "[7,6,0,0]";
	assert numberCopy([], [], RaiserOpcode.ArrayConcat, 0, 0) == "[]";
}

test "array kernels: pop and shift hand the element out, an empty shift gives the zero of its class and an empty pop is fatal" {
	const vm = kernelVM([RaiserRegClass.Ref, RaiserRegClass.Float], [
		raiserABC(RaiserOpcode.ArrayPop, 1, 0, 0),
		raiserABC(RaiserOpcode.Print, 1, 0, 0),
		raiserABC(RaiserOpcode.ArrayShift, 1, 0, 0),
		raiserABC(RaiserOpcode.Print, 1, 0, 0),
		raiserABC(RaiserOpcode.ArrayShift, 1, 0, 0),
		raiserABC(RaiserOpcode.Print, 1, 0, 0),
		raiserABC(RaiserOpcode.ArrayPop, 1, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], []);
	vm.regs.slots[0] = numberArray(vm, [1, 2]);
	execLoop(vm);
	assert vm.output == "2\n1\n0\n", vm.output;
	assert vm.error.includes("index -1 out of bounds (length 0)"), vm.error;
}

function stringKernel(texts: string[], code: RaiserInstruction[], consts: RaiserValue[]): RaiserVM {
	const vm = kernelVM([RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Ref], code, consts);
	const elems: RaiserValue[] = [];
	for (const t of texts) elems.push(ownedString(vm, t));
	vm.regs.slots[0] = refArray(vm, elems);
	return vm;
}

function elemAt(vm: RaiserVM, handle: int64, i: number): RaiserValue {
	return heapArrayGet(vm.arrayHeap, handle, i as int64);
}

test "array kernels: slice, concat, splice, pop and fill count string elements" {
	const range = [raiserABx(RaiserOpcode.LoadConst, 2, 0), raiserABx(RaiserOpcode.LoadConst, 3, 1)];
	const halt = raiserABC(RaiserOpcode.Halt, 0, 0, 0);
	const abc = ["p", "q", "r"];

	const sliced = stringKernel(abc, [...range, raiserABC(RaiserOpcode.ArraySliceCopy, 1, 0, 2), halt], [raiserInt(1), raiserInt(3)]);
	const slicedFrom = elemAt(sliced, sliced.regs.slots[0], 0);
	execLoop(sliced);
	assert heldText(sliced, sliced.regs.slots[1]) == "[q,r]";
	assert stringRc(sliced, slicedFrom) == 1 && stringRc(sliced, elemAt(sliced, sliced.regs.slots[0], 1)) == 2 && stringRc(sliced, elemAt(sliced, sliced.regs.slots[0], 2)) == 2;
	assert heapArrayRc(sliced.arrayHeap, sliced.regs.slots[1]) == 1;

	const joined = stringKernel(abc, [raiserABC(RaiserOpcode.ArrayConcat, 1, 0, 0), halt], []);
	execLoop(joined);
	assert heldText(joined, joined.regs.slots[1]) == "[p,q,r,p,q,r]" && stringRc(joined, elemAt(joined, joined.regs.slots[0], 1)) == 3;

	const spliced = stringKernel(abc, [...range, raiserABC(RaiserOpcode.ArraySplice, 0, 0, 2), halt], [raiserInt(1), raiserInt(1)]);
	const survivor = elemAt(spliced, spliced.regs.slots[0], 2);
	const splicedLive = heapStringLive(spliced.arrayHeap);
	execLoop(spliced);
	assert heldText(spliced, spliced.regs.slots[0]) == "[p,r]" && heapStringLive(spliced.arrayHeap) == splicedLive - 1 && stringRc(spliced, survivor) == 1;

	const inserted = stringKernel(abc, [...range, raiserABC(RaiserOpcode.ArraySplice3, 0, 4, 2), halt], [raiserInt(1), raiserInt(1)]);
	inserted.regs.slots[4] = elemAt(inserted, inserted.regs.slots[0], 0).intVal;
	const insertedLive = heapStringLive(inserted.arrayHeap);
	execLoop(inserted);
	assert heldText(inserted, inserted.regs.slots[0]) == "[p,p,r]" && heapStringLive(inserted.arrayHeap) == insertedLive - 1 && stringRc(inserted, handleValue(inserted.regs.slots[4])) == 2;

	const itself = stringKernel(abc, [...range, raiserABC(RaiserOpcode.ArraySplice3, 0, 4, 2), halt], [raiserInt(1), raiserInt(1)]);
	itself.regs.slots[4] = elemAt(itself, itself.regs.slots[0], 1).intVal;
	const itselfLive = heapStringLive(itself.arrayHeap);
	execLoop(itself);
	assert heldText(itself, itself.regs.slots[0]) == "[p,q,r]" && heapStringLive(itself.arrayHeap) == itselfLive && stringRc(itself, handleValue(itself.regs.slots[4])) == 1;

	const popped = stringKernel(abc, [raiserABC(RaiserOpcode.ArrayPop, 1, 0, 0), raiserABC(RaiserOpcode.ArrayShift, 4, 0, 0), halt], []);
	execLoop(popped);
	assert heldText(popped, popped.regs.slots[0]) == "[q]" && stringRc(popped, handleValue(popped.regs.slots[1])) == 1 && stringRc(popped, handleValue(popped.regs.slots[4])) == 1;

	const filled = stringKernel(abc, [raiserABC(RaiserOpcode.ArrayFill, 0, 4, 0), halt], []);
	const z = ownedString(filled, "z");
	filled.regs.slots[4] = z.intVal;
	const filledLive = heapStringLive(filled.arrayHeap);
	execLoop(filled);
	assert heldText(filled, filled.regs.slots[0]) == "[z,z,z]" && heapStringLive(filled.arrayHeap) == filledLive - 3 && stringRc(filled, z) == 4;
}

test "array kernels: a sort of strings is by bytes and keeps equal strings in their order" {
	const texts = ["pear", "apple", "fig", "apple", "Zed", "fig", ""];
	const vm = stringKernel(texts, [raiserABC(RaiserOpcode.ArraySort, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], []);
	const before = vm.regs.slots[0];
	const handles: int64[] = [];
	for (let i = 0; i < texts.length; i += 1) handles.push(elemAt(vm, before, i).intVal);
	execLoop(vm);
	assert vm.error == "", vm.error;
	assert heldText(vm, vm.regs.slots[0]) == "[,Zed,apple,apple,fig,fig,pear]", heldText(vm, vm.regs.slots[0]);
	const sorted = vm.regs.slots[0];
	assert elemAt(vm, sorted, 2).intVal == handles[1] && elemAt(vm, sorted, 3).intVal == handles[3];
	assert elemAt(vm, sorted, 4).intVal == handles[2] && elemAt(vm, sorted, 5).intVal == handles[5];
	const reversed = stringKernel(["a", "b", "c"], [raiserABC(RaiserOpcode.ArrayReverse, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], []);
	execLoop(reversed);
	assert heldText(reversed, reversed.regs.slots[0]) == "[c,b,a]";
}

test "array kernels: an empty shift of strings gives \"\" or nil by the instruction's flag" {
	const asString = stringKernel([], [raiserABC(RaiserOpcode.ArrayShift, 1, 0, 1), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], []);
	execLoop(asString);
	assert asString.error == "" && raiserToString(asString.arrayHeap, handleValue(asString.regs.slots[1])) == "";
	assert handleTag(asString.regs.slots[1]) == (RaiserHeapKind.ConstString as int64);
	const asObject = stringKernel([], [raiserABC(RaiserOpcode.ArrayShift, 1, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], []);
	execLoop(asObject);
	assert asObject.error == "" && asObject.regs.slots[1] == 0;
}

test "array kernels: a view is read by slice and concat and refused by every kernel that rewrites" {
	const ops = [RaiserOpcode.ArrayReverse, RaiserOpcode.ArraySort];
	for (const op of ops) {
		const vm = stringKernel(["b", "a", "c"], [raiserABC(op, 1, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], []);
		vm.regs.slots[1] = heapAllocView(vm.arrayHeap, handleValue(vm.regs.slots[0]), 1, 2);
		execLoop(vm);
		assert vm.error.includes("a slice"), vm.error;
	}
	const popping = stringKernel(["b", "a", "c"], [raiserABC(RaiserOpcode.ArrayPop, 4, 1, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], []);
	popping.regs.slots[1] = heapAllocView(popping.arrayHeap, handleValue(popping.regs.slots[0]), 1, 2);
	execLoop(popping);
	assert popping.error.includes("cannot pop from a slice"), popping.error;
	const reading = stringKernel(["b", "a", "c"], [
		raiserABx(RaiserOpcode.LoadConst, 2, 0), raiserABx(RaiserOpcode.LoadConst, 3, 1),
		raiserABC(RaiserOpcode.ArraySliceCopy, 4, 1, 2), raiserABC(RaiserOpcode.ArrayConcat, 4, 1, 1),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserInt(0), raiserInt(5)]);
	reading.regs.slots[1] = heapAllocView(reading.arrayHeap, handleValue(reading.regs.slots[0]), 1, 2);
	execLoop(reading);
	assert heldText(reading, reading.regs.slots[4]) == "[a,c,a,c]", heldText(reading, reading.regs.slots[4]);
}

test "array kernels: a fill with a value the element class cannot hold is refused before any element changes" {
	const vm = kernelVM([RaiserRegClass.Ref, RaiserRegClass.Ref], [raiserABC(RaiserOpcode.ArrayFill, 0, 1, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)], []);
	vm.regs.slots[0] = numberArray(vm, [1, 2]);
	vm.regs.slots[1] = heapAllocString(vm.arrayHeap, "s").intVal;
	execLoop(vm);
	assert vm.error != "" && heldText(vm, vm.regs.slots[0]) == "[1,2]", vm.error;
}

test "array kernels: object elements are shared by a slice and freed by the splice that evicts the last holder" {
	const range = [raiserABx(RaiserOpcode.LoadConst, 2, 0), raiserABx(RaiserOpcode.LoadConst, 3, 1)];
	const halt = raiserABC(RaiserOpcode.Halt, 0, 0, 0);
	const make = (code: RaiserInstruction[], consts: RaiserValue[]): RaiserVM => {
		const vm = kernelVM([RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Ref], code, consts);
		vm.regs.slots[0] = refArray(vm, [ownedObject(vm), ownedObject(vm), ownedObject(vm)]);
		return vm;
	};
	const evicting = make([...range, raiserABC(RaiserOpcode.ArraySplice, 0, 0, 2), halt], [raiserInt(0), raiserInt(99)]);
	execLoop(evicting);
	assert vmLiveCount(evicting) == 1 && heapArrayLen(evicting.arrayHeap, evicting.regs.slots[0]) == 0, `${vmLiveCount(evicting)}`;
	const sliced = make([...range, raiserABC(RaiserOpcode.ArraySliceCopy, 1, 0, 2), halt], [raiserInt(0), raiserInt(2)]);
	execLoop(sliced);
	assert objectRc(sliced, elemAt(sliced, sliced.regs.slots[0], 0)) == 2 && objectRc(sliced, elemAt(sliced, sliced.regs.slots[0], 2)) == 1;
}

function returnThroughFinally(): RaiserVM {
	const mainCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Call, 1, 1, 0),
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	];
	const guardedCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.Try, 0, 3),
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
		raiserABx(RaiserOpcode.Catch, 1, 2),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
		raiserABC(RaiserOpcode.Finally, 2, 1, 0),
		raiserABC(RaiserOpcode.FinallyEnd, 2, 1, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const fMain = createRaiserFunction("main", mainCode, [], 0, 0, 2, [RaiserRegClass.Word, RaiserRegClass.Word]);
	const fGuarded = createRaiserFunction("guarded", guardedCode, [raiserInt(7)], 0, 0, 4, [RaiserRegClass.Word, RaiserRegClass.Dyn, RaiserRegClass.Word, RaiserRegClass.Dyn]);
	return execModule(createRaiserModule("placed", [fMain, fGuarded], 0));
}

test "a return through a finally frees the box that held it" {
	const vm = returnThroughFinally();
	assert vm.error == "" && vm.exitValue.intVal == 7, vm.error;
	assert heapBoxLive(vm.arrayHeap) == 0, `${heapBoxLive(vm.arrayHeap)}`;
}

test "placed: AssignInPlace gives an array behind a pointer the source's elements, releases the old ones and frees the source cell" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		slotted(raiserABC(RaiserOpcode.NewArray, 0, 0, 0), arrayClassSlot(RaiserRegClass.Ref)),
		raiserABC(RaiserOpcode.ArrayPush, 0, 1, 0),
		raiserABC(RaiserOpcode.WasMoved, 1, 0, 0),
		raiserABC(RaiserOpcode.Move, 2, 0, 0),
		raiserABC(RaiserOpcode.RcInc, 2, 0, 0),
		slotted(raiserABC(RaiserOpcode.NewArray, 3, 0, 0), arrayClassSlot(RaiserRegClass.Ref)),
		raiserABC(RaiserOpcode.NewObject, 1, 1, 0),
		raiserABC(RaiserOpcode.ArrayPush, 3, 1, 0),
		raiserABC(RaiserOpcode.WasMoved, 1, 0, 0),
		raiserABC(RaiserOpcode.NewObject, 4, 1, 0),
		raiserABC(RaiserOpcode.ArrayPush, 3, 4, 0),
		raiserABC(RaiserOpcode.WasMoved, 4, 0, 0),
		raiserABC(RaiserOpcode.AssignInPlace, 0, 3, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref], [leaf], []);
	main.copyPlans = [copyPlan(RaiserCopyKind.Array, [], [1]), copyPlan(RaiserCopyKind.Object, [], [])];
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vm.regs.slots[0] == vm.regs.slots[2] && vm.regs.slots[3] == 0, `${vm.regs.slots[0]} ${vm.regs.slots[2]} ${vm.regs.slots[3]}`;
	const dest = vm.regs.slots[0];
	assert heapArrayLen(vm.arrayHeap, dest) == 2 && heapArrayRc(vm.arrayHeap, dest) == 2, `${heapArrayLen(vm.arrayHeap, dest)} ${heapArrayRc(vm.arrayHeap, dest)}`;
	assert vmLiveCount(vm) == 3, `${vmLiveCount(vm)}`;
}

test "placed: AssignInPlace gives a union behind a pointer the source's tag and payload, releases the old payload and frees the source cell" {
	const union = createClassType("U", -1, [], ["_tag", "v0"], [RaiserRegClass.Word, RaiserRegClass.Ref]);
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 2, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 1, 1), 1),
		raiserABC(RaiserOpcode.WasMoved, 1, 0, 0),
		raiserABC(RaiserOpcode.Move, 2, 0, 0),
		raiserABC(RaiserOpcode.RcInc, 2, 0, 0),
		raiserABC(RaiserOpcode.NewObject, 3, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 4, 2, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 3, 1, 4), 1),
		raiserABC(RaiserOpcode.WasMoved, 4, 0, 0),
		raiserABC(RaiserOpcode.AssignInPlace, 0, 3, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref], [union, leaf], ["_tag", "v0"]);
	const arm = copyPlan(RaiserCopyKind.Object, ["v0"], [2]);
	const whole: RaiserCopyPlan = { kind: RaiserCopyKind.Union, names: ["_tag"], children: [1], discriminants: [0], laid: RAISER_NO_CLASS, laidChildren: [] };
	main.copyPlans = [whole, arm, copyPlan(RaiserCopyKind.Object, [], [])];
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vm.regs.slots[0] == vm.regs.slots[2] && vm.regs.slots[3] == 0, `${vm.regs.slots[0]} ${vm.regs.slots[2]} ${vm.regs.slots[3]}`;
	const dest = vm.regs.slots[0];
	assert objectCellSlot(seqCellOf(dest), 1) != 0 && rcCountOf(vm.arrayHeap, vm.objectHeap, dest) == 2, `${rcCountOf(vm.arrayHeap, vm.objectHeap, dest)}`;
	assert vmLiveCount(vm) == 2, `${vmLiveCount(vm)}`;
}

const pendingClasses: RaiserRegClass[] = [RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Dyn, RaiserRegClass.Word, RaiserRegClass.Word];

function throwFromFinallyBody(): RaiserVM {
	const mainCode: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.Call, 1, 1, 0),
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	];
	const guardedCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.Try, 0, 11),
		raiserABx(RaiserOpcode.Try, 0, 3),
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
		raiserABx(RaiserOpcode.Catch, 1, 2),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
		raiserABC(RaiserOpcode.Finally, 2, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 5, 1),
		raiserABC(RaiserOpcode.Throw, 5, 0, 0),
		raiserABC(RaiserOpcode.FinallyEnd, 2, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
		raiserABx(RaiserOpcode.Catch, 4, 1),
		raiserABx(RaiserOpcode.LoadConst, 0, 2),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const fMain = createRaiserFunction("main", mainCode, [], 0, 0, 2, [RaiserRegClass.Word, RaiserRegClass.Word]);
	const fGuarded = createRaiserFunction("guarded", guardedCode, [raiserInt(7), raiserInt(8), raiserInt(9)], 0, 0, 6, pendingClasses);
	return execModule(createRaiserModule("placed", [fMain, fGuarded], 0));
}

function frameUnwoundWhilePending(): RaiserVM {
	const mainCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.Try, 0, 3),
		raiserABC(RaiserOpcode.Call, 1, 1, 0),
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
		raiserABx(RaiserOpcode.Catch, 2, 1),
		raiserABC(RaiserOpcode.Halt, 2, 0, 0),
	];
	const guardedCode: RaiserInstruction[] = [
		raiserABx(RaiserOpcode.Try, 0, 4),
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
		raiserAx(RaiserOpcode.Jump, 0),
		raiserABC(RaiserOpcode.Finally, 2, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 5, 1),
		raiserABC(RaiserOpcode.Throw, 5, 0, 0),
		raiserABC(RaiserOpcode.FinallyEnd, 2, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	];
	const fMain = createRaiserFunction("main", mainCode, [], 0, 0, 3, [RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Word]);
	const fGuarded = createRaiserFunction("guarded", guardedCode, [raiserInt(7), raiserInt(8)], 0, 0, 6, pendingClasses);
	return execModule(createRaiserModule("placed", [fMain, fGuarded], 0));
}

test "a throw out of a finally body frees the box of the return it interrupted" {
	const vm = throwFromFinallyBody();
	assert vm.error == "" && vm.exitValue.intVal == 9, `${vm.error} ${vm.exitValue.intVal}`;
	assert heapBoxLive(vm.arrayHeap) == 0 && vm.safePoints.length == 0, `${heapBoxLive(vm.arrayHeap)} ${vm.safePoints.length}`;
}

test "a frame unwound by a throw from its finally frees the box of the return it interrupted" {
	const vm = frameUnwoundWhilePending();
	assert vm.error == "" && vm.exitValue.intVal == 8, `${vm.error} ${vm.exitValue.intVal}`;
	assert heapBoxLive(vm.arrayHeap) == 0 && vm.safePoints.length == 0, `${heapBoxLive(vm.arrayHeap)} ${vm.safePoints.length}`;
}

test "placed: a tag read by LoadField into a Dyn register inside a destroy routine leaves no box behind" {
	const cell = createClassType("Cell", -1, [], ["n", "child"], [RaiserRegClass.Word, RaiserRegClass.Ref]);
	const leaf = createClassType("Leaf", -1, [], [], []);
	cell.destroyFn = 1;
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.NewObject, 1, 2, 0),
		raiserABC(RaiserOpcode.LoadInt, 2, immField(7), 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 0, 2), 0),
		raiserABC(RaiserOpcode.RcInc, 1, 0, 0),
		slotted(raiserABC(RaiserOpcode.StoreSlot, 0, 1, 1), 1),
		raiserABC(RaiserOpcode.RcDec, 1, 0, 0),
		raiserABC(RaiserOpcode.RcDec, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Word], [cell, leaf], ["n", "child"]);
	const destroy = createRaiserFunction("destroy", [
		raiserABC(RaiserOpcode.LoadField, 1, 0, 0),
		raiserABC(RaiserOpcode.Print, 1, 0, 0),
		slotted(raiserABC(RaiserOpcode.LoadSlot, 2, 0, 1), 1),
		raiserABC(RaiserOpcode.RcDec, 2, 0, 0),
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	], fieldNames(["n", "child"]), 1, 1, 3, [RaiserRegClass.Ref, RaiserRegClass.Dyn, RaiserRegClass.Ref]);
	const vm = execModule(createRaiserModule("placed", [main, destroy], 0));
	assert vm.error == "", vm.error;
	assert vm.output == "7\n", vm.output;
	assert heapBoxLive(vm.arrayHeap) == 0 && vmLiveCount(vm) == 0, `${heapBoxLive(vm.arrayHeap)} ${vmLiveCount(vm)}`;
}

test "placed: a Dyn register overwritten again and again frees the box each overwrite replaces" {
	const main = createRaiserFunction("main", [
		raiserABC(RaiserOpcode.LoadInt, 2, immField(5), 0),
		raiserABC(RaiserOpcode.Box, 1, 2, 0),
		raiserABC(RaiserOpcode.Box, 1, 2, 0),
		raiserABC(RaiserOpcode.Box, 1, 2, 0),
		raiserABC(RaiserOpcode.Box, 1, 2, 0),
		raiserABC(RaiserOpcode.Box, 1, 2, 0),
		raiserABC(RaiserOpcode.LoadNil, 1, 0, 0),
		raiserABC(RaiserOpcode.Halt, 2, 0, 0),
	], [raiserInt(5)], 0, 0, 3, [RaiserRegClass.Ref, RaiserRegClass.Dyn, RaiserRegClass.Word]);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert vm.exitValue.intVal == 5, `${vm.exitValue.intVal}`;
	assert heapBoxLive(vm.arrayHeap) == 0, `${heapBoxLive(vm.arrayHeap)}`;
}

test "placed: overwriting a Dyn register frees the shell around a string and leaves the string to its own RcDec" {
	const main = createRaiserFunction("main", [
		raiserABx(RaiserOpcode.LoadConst, 0, 0),
		raiserABx(RaiserOpcode.LoadConst, 1, 0),
		raiserABC(RaiserOpcode.ConcatStr, 2, 0, 1),
		raiserABC(RaiserOpcode.Box, 3, 2, 0),
		raiserABC(RaiserOpcode.LoadNil, 3, 0, 0),
		raiserABC(RaiserOpcode.RcDec, 2, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserConstString("ab")], 0, 0, 4, [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Dyn]);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert heapBoxLive(vm.arrayHeap) == 0 && heapStringLive(vm.arrayHeap) == 0, `${heapBoxLive(vm.arrayHeap)} ${heapStringLive(vm.arrayHeap)}`;
}

test "placed: a store through an array cell names the function and instruction that wrote" {
	const main = mainWithClasses([
		slotted(raiserABC(RaiserOpcode.NewArray, 0, 0, 0), arrayClassSlot(RaiserRegClass.Ref)),
		slotted(raiserABC(RaiserOpcode.NewArray, 1, 0, 0), arrayClassSlot(RaiserRegClass.Ref)),
		raiserABC(RaiserOpcode.StoreDeref, 0, 0, 1),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [], []);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error.startsWith("internal: cannot write through a value of kind Array") && vm.error.endsWith(" at instruction 2)"), vm.error;
}

test "placed: an operand of the wrong kind names the function and instruction that read it" {
	const main = mainWithClasses([
		slotted(raiserABC(RaiserOpcode.NewArray, 0, 0, 0), arrayClassSlot(RaiserRegClass.Ref)),
		raiserABC(RaiserOpcode.LoadField, 1, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref], [], ["f"]);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error.startsWith("internal: expected an object, got value kind Array") && vm.error.endsWith(" at instruction 1)"), vm.error;
}

test "placed: a nil stored through an array cell empties the cell in place and releases nothing" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		slotted(raiserABC(RaiserOpcode.NewArray, 0, 0, 0), arrayClassSlot(RaiserRegClass.Ref)),
		raiserABC(RaiserOpcode.NewObject, 2, 1, 0),
		raiserABC(RaiserOpcode.ArrayPush, 0, 2, 0),
		raiserABC(RaiserOpcode.WasMoved, 2, 0, 0),
		raiserABC(RaiserOpcode.LoadNil, 1, 0, 0),
		raiserABC(RaiserOpcode.StoreDeref, 0, 0, 1),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Ref, RaiserRegClass.Ref], [leaf], []);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert heapArrayLen(vm.arrayHeap, vm.regs.slots[0]) == 0, `${heapArrayLen(vm.arrayHeap, vm.regs.slots[0])}`;
}

test "placed: RcDec on a Dyn register frees the object it holds the last reference to, and the shell goes at the next overwrite" {
	const leaf = createClassType("Leaf", -1, [], [], []);
	const main = mainWithClasses([
		raiserABC(RaiserOpcode.NewObject, 0, 1, 0),
		raiserABC(RaiserOpcode.Box, 1, 0, 0),
		raiserABC(RaiserOpcode.WasMoved, 0, 0, 0),
		raiserABC(RaiserOpcode.RcDec, 1, 0, 0),
		raiserABC(RaiserOpcode.LoadNil, 1, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [RaiserRegClass.Ref, RaiserRegClass.Dyn], [leaf], []);
	const vm = execModule(createRaiserModule("placed", [main], 0));
	assert vm.error == "", vm.error;
	assert heapBoxLive(vm.arrayHeap) == 0 && vmLiveCount(vm) == 0, `${heapBoxLive(vm.arrayHeap)} ${vmLiveCount(vm)}`;
}
