// Raiser VM — Host function registry
//
// Module-level singleton table mapping native names to wrapper functions.
// Populated lazily on first VM use (see compiler/meta/comptime.ms) from the
// auto-generated host table (codegen/raiser/hostTable.ms emits MS source
// that calls registerHostFn for every reachable extern).
//
// Linear-scan lookup is fine for the expected size range (~50-200 entries).
// Swap to a hash map if profiling shows it matters.

import { RaiserHostFn } from "./marshal";
import { RaiserObjectHeap, RaiserArrayHeap } from "./value";

interface HostEntry {
	name: string;
	fn: RaiserHostFn;
}

interface HostRegistry {
	entries: HostEntry[];
	initialized: boolean;
}

// Module-level singleton. Initialized empty; populated by registerHostFn.
const _registry: HostRegistry = { entries: [], initialized: false };

// --- Public API ---

export function registerHostFn(name: string, fn: RaiserHostFn): void {
	// Allow re-registration (last write wins) — Phase 5 may re-populate
	// across compiler reruns in long-running build processes.
	for (const entry of _registry.entries) {
		if (entry.name === name) {
			entry.fn = fn;
			return;
		}
	}
	const newEntry: HostEntry = { name, fn };
	_registry.entries.push(newEntry);
}

export function lookupHostFn(name: string): RaiserHostFn {
	for (const entry of _registry.entries) {
		if (entry.name === name) {
			return entry.fn;
		}
	}
	return null as unknown as RaiserHostFn;
}

export function isHostRegistryInitialized(): boolean {
	return _registry.initialized;
}

export function markHostRegistryInitialized(): void {
	_registry.initialized = true;
}

export function hostRegistrySize(): number {
	return _registry.entries.length;
}

// --- Active VM heaps ---
// Bridges receive RaiserValue args by value; an Object/Array value is only a
// handle, so a bridge that must dereference one (msNodeChildCount/At) needs
// the executing VM's heaps. vmHandleCallHost publishes them here before each
// dispatch and restores the previous pair after, so nested VM runs inside a
// bridge leave the outer VM's heaps active when the outer bridge resumes.

let _activeObjectHeap: RaiserObjectHeap | null = null;
let _activeArrayHeap: RaiserArrayHeap | null = null;

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

// Test-only: reset state between test runs.
export function _resetHostRegistryForTests(): void {
	_registry.entries.length = 0;
	_registry.initialized = false;
	_activeObjectHeap = null;
	_activeArrayHeap = null;
}

// --- Tests ---

import { RaiserValue } from "./value";
import { raiserString, raiserInt, RaiserValueKind, createStructHeap, createArrayHeap } from "./value";

test "register and lookup host fn" {
	_resetHostRegistryForTests();
	const echoFn: RaiserHostFn = (args: RaiserValue[]): RaiserValue => {
		return args[0];
	};
	registerHostFn("echo", echoFn);
	const fn = lookupHostFn("echo");
	assert fn !== null;
	const result = fn([raiserString("hello")]);
	assert result.kind === RaiserValueKind.String;
	assert result.strVal === "hello";
}

test "lookup missing returns null" {
	_resetHostRegistryForTests();
	const fn = lookupHostFn("nonexistent");
	assert fn === null;
}

test "registry size tracks entries" {
	_resetHostRegistryForTests();
	assert hostRegistrySize() === 0;
	const fn1: RaiserHostFn = (args: RaiserValue[]): RaiserValue => args[0];
	const fn2: RaiserHostFn = (args: RaiserValue[]): RaiserValue => args[0];
	registerHostFn("a", fn1);
	registerHostFn("b", fn2);
	assert hostRegistrySize() === 2;
}

test "re-registration overwrites" {
	_resetHostRegistryForTests();
	const fnA: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(1);
	const fnB: RaiserHostFn = (args: RaiserValue[]): RaiserValue => raiserInt(2);
	registerHostFn("dup", fnA);
	registerHostFn("dup", fnB);
	assert hostRegistrySize() === 1;
	const fn = lookupHostFn("dup");
	const result = fn([]);
	assert result.intVal === 2;
}

test "initialized flag" {
	_resetHostRegistryForTests();
	assert isHostRegistryInitialized() === false;
	markHostRegistryInitialized();
	assert isHostRegistryInitialized() === true;
}

test "active host heaps publish and read back" {
	const oh = createStructHeap();
	const ah = createArrayHeap();
	setActiveHostHeaps(oh, ah);
	assert activeHostObjectHeap() !== null;
	assert activeHostArrayHeap() !== null;
}
