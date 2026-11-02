export { Promise, spawn, sleepAsync } from "./kernel";

// asyncCheck — fire-and-forget for async calls (reference asyncCheck parity).
// Starts the async function and raises on error. Does NOT block.
// Use instead of discarding the return value of an async call.
export function asyncCheck(fut: Promise<void>): void {
	// Future is already started (stepper runs via msAsyncCb).
	// Just register an error callback so failures don't go silent.
	// TODO: add error re-raise callback (raise fut.error on failure)
}

// ===== Locked<T> — the one sanctioned shared-mutable cell (PARALOCK I22) =====
// `Locked<T>` is a compiler-known type: ONE allocation holding the atomic-rc
// header, an inline ticket lock and a typed payload, so the handle IS an atomic
// reference and needs no second refcount wrapper (`Arc<Locked<T>>` is not a
// type). The payload is never addressable from the surface — it is reached only
// inside the callbacks below, which ARE the critical section.

@include("runtime/promise/locked.h");

extern function msLockedAcquire<T>(cell: Locked<T>): void from "msLockedAcquire";
extern function msLockedRelease<T>(cell: Locked<T>): void from "msLockedRelease";
// Payload load/store: rewritten by the C backend into a field access on the
// generated cell struct, so the payload offset always comes from the struct
// itself. They are deliberately private — a load outside the critical section
// would hand out a racy copy.
@builtin("LockedLoad")
extern function msLockedLoad<T>(cell: Locked<T>): T;
@builtin("LockedStore")
extern function msLockedStore<T>(cell: Locked<T>, value: T): void;

// Read-modify-write under the lock. The callback IS the critical section, so it
// must stay short and must never await or block (PARALOCK Amendment E).
export function lockedUpdate<T>(cell: Locked<T>, fn: (value: T) => T): void {
	msLockedAcquire(cell);
	defer msLockedRelease(cell);
	msLockedStore(cell, fn(msLockedLoad(cell)));
}

// Read under the lock. What leaves the cell is a copy of the payload (or a value
// derived from it), never a reference into shared mutable state.
export function lockedRead<T, R>(cell: Locked<T>, fn: (value: T) => R): R {
	msLockedAcquire(cell);
	defer msLockedRelease(cell);
	return fn(msLockedLoad(cell));
}
