// Raiser VM — Host function registry
//
// Module-level singleton table mapping native names to wrapper functions.
// Populated lazily on first VM use (see compiler/meta/comptime.ms) from the
// auto-generated host table (codegen/raiser/hostTable.ms emits MS source
// that calls registerHostFn for every reachable extern).
//
import { RaiserHostFn } from "./marshal";
import { RaiserObjectHeap, RaiserArrayHeap, createStructHeap, createArrayHeap } from "./value";

export enum HostCapability {
	Unsafe,
	Pure,
	FileRead,
	ChildProcess,
}

export interface HostEntry {
	name: string;
	fn: RaiserHostFn;
	capability: HostCapability;
	live: boolean;  // false once _resetHostRegistryForTests dropped it, so a call site that cached it resolves again
}

interface HostRegistry {
	entries: Map<string, HostEntry>;
	initialized: boolean;
}

// Module-level singleton. Initialized empty; populated by registerHostFn.
const _registry: HostRegistry = { entries: new Map<string, HostEntry>(), initialized: false };

// --- Public API ---

export function registerHostFn(
	name: string,
	fn: RaiserHostFn,
	capability: HostCapability = HostCapability.Unsafe,
): void {
	// Last write wins and the entry object stays, so a call site that cached it sees the new fn.
	if (_registry.entries.has(name)) {
		const entry = _registry.entries.get(name)!;
		entry.fn = fn;
		entry.capability = capability;
		return;
	}
	const newEntry: HostEntry = { name, fn, capability, live: true };
	_registry.entries.set(name, newEntry);
}

export function lookupHost(name: string): HostEntry | null {
	if (!_registry.entries.has(name)) return null;
	return _registry.entries.get(name)!;
}

export function hostEntryAllowedInRestrictedMode(entry: HostEntry): boolean {
	return entry.capability == HostCapability.Pure || entry.capability == HostCapability.FileRead;
}

export function hostEntrySpawnsChild(entry: HostEntry): boolean {
	return entry.capability == HostCapability.ChildProcess;
}

export function isHostRegistryInitialized(): boolean {
	return _registry.initialized;
}

export function markHostRegistryInitialized(): void {
	_registry.initialized = true;
}

export function hostRegistrySize(): number {
	return _registry.entries.size;
}

// --- Active VM heaps ---
// Bridges receive RaiserValue args by value; an Object/Array value is only a
// handle, so a bridge that must dereference one (msNodeChildCount/At) needs
// the executing VM's heaps. vmHandleCallHost publishes them here before each
// dispatch and restores the previous pair after, so nested VM runs inside a
// bridge leave the outer VM's heaps active when the outer bridge resumes.

let _activeObjectHeap: RaiserObjectHeap | null = null;
let _activeArrayHeap: RaiserArrayHeap | null = null;
let _activeProgramArgv: string[] | null = null;

export function setActiveHostHeaps(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap): void {
	_activeObjectHeap = objHeap;
	_activeArrayHeap = arrHeap;
}

export function activeHostObjectHeap(): RaiserObjectHeap | null {
	return _activeObjectHeap;
}

export function activeHostArrayHeap(): RaiserArrayHeap | null {
	return _activeArrayHeap;
}

let _hostRaise: string | null = null;
let _hostRaiseFatal: boolean = false;

export function raiseFromHost(message: string, fatal: boolean): void {
	_hostRaise = message;
	_hostRaiseFatal = fatal;
}

export function hostRaiseIsFatal(): boolean {
	return _hostRaiseFatal;
}

export function takeHostRaise(): string | null {
	const message = _hostRaise;
	_hostRaise = null;
	_hostRaiseFatal = false;
	return message;
}

export function setActiveProgramArgv(programArgv: string[] | null): void {
	_activeProgramArgv = programArgv;
}

export function activeProgramArgv(): string[] | null {
	return _activeProgramArgv;
}

// Test-only: reset state between test runs.
export function _resetHostRegistryForTests(): void {
	for (const name of _registry.entries) _registry.entries.get(name)!.live = false;
	_registry.entries.clear();
	_registry.initialized = false;
	_activeObjectHeap = createStructHeap();
	_activeArrayHeap = createArrayHeap();
	_activeProgramArgv = null;
	_hostRaise = null;
	_hostRaiseFatal = false;
}

// --- Tests ---

import { RaiserValue } from "./value";
import { raiserConstString, raiserInt, RaiserValueKind, heapStringText } from "./value";

test "register and lookup host fn" {
	_resetHostRegistryForTests();
	const echoFn: RaiserHostFn = (args: RaiserValue[]): RaiserValue => {
		return args[0];
	};
	registerHostFn("echo", echoFn);
	const entry = lookupHost("echo");
	assert entry != null;
	const result = entry!.fn([raiserConstString("hello")]);
	assert result.kind == RaiserValueKind.String;
	assert heapStringText(createArrayHeap(), result) == "hello";
}

test "lookup missing returns null" {
	_resetHostRegistryForTests();
	assert lookupHost("nonexistent") == null;
}

test "registry size tracks entries" {
	_resetHostRegistryForTests();
	assert hostRegistrySize() == 0;
	const fn1: RaiserHostFn = (args: RaiserValue[]): RaiserValue => args[0];
	const fn2: RaiserHostFn = (args: RaiserValue[]): RaiserValue => args[0];
	registerHostFn("a", fn1);
	registerHostFn("b", fn2);
	assert hostRegistrySize() == 2;
}

test "re-registration overwrites" {
	_resetHostRegistryForTests();
	const fnA: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(1);
	const fnB: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(2);
	registerHostFn("dup", fnA);
	registerHostFn("dup", fnB);
	assert hostRegistrySize() == 1;
	const first = lookupHost("dup")!;
	registerHostFn("dup", fnA);
	assert first.fn([]).intVal == 1;
	assert lookupHost("dup")!.fn([]).intVal == 1;
	registerHostFn("dup", fnB);
	assert first.fn([]).intVal == 2;
	assert first.live;
	_resetHostRegistryForTests();
	assert !first.live;
	assert lookupHost("dup") == null;
}

test "initialized flag" {
	_resetHostRegistryForTests();
	assert isHostRegistryInitialized() == false;
	markHostRegistryInitialized();
	assert isHostRegistryInitialized() == true;
}

test "restricted host access allows only classified pure and file-read hosts" {
	_resetHostRegistryForTests();
	const fn: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(args.length);
	registerHostFn("unsafe", fn);
	registerHostFn("pure", fn, HostCapability.Pure);
	registerHostFn("read", fn, HostCapability.FileRead);
	assert !hostEntryAllowedInRestrictedMode(lookupHost("unsafe")!);
	assert hostEntryAllowedInRestrictedMode(lookupHost("pure")!);
	assert hostEntryAllowedInRestrictedMode(lookupHost("read")!);
	assert lookupHost("missing") == null;
}

test "active host heaps publish and read back" {
	const oh = createStructHeap();
	const ah = createArrayHeap();
	setActiveHostHeaps(oh, ah);
	assert activeHostObjectHeap() != null;
	assert activeHostArrayHeap() != null;
}

test "active program argv publishes, reads back and resets" {
	_resetHostRegistryForTests();
	assert activeProgramArgv() == null;
	setActiveProgramArgv(["tool.ms", "a"]);
	const got = activeProgramArgv();
	assert got != null;
	if (got != null) {
		assert got.length == 2;
		assert got[1] == "a";
	}
	_resetHostRegistryForTests();
	assert activeProgramArgv() == null;
}
