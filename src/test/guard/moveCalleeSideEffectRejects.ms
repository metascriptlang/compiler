// nim-guard: spawn { move } — a value built by a call or `new` is fresh only
//   when the callee has no side effect.
//
// INVARIANT (isolation check, callee purity): a moved binding may be bound
//   from a call, a `new`, or a method call on itself only when that routine,
//   and every routine it calls, reads and writes no mutable or ref-holding
//   module-level state and calls no external or unknown function. Such a
//   routine can keep no alias of what it returns, so the move is whole.
//
// WHAT IT CATCHES: the sole-owner rule accepting a call by its argument shape
//   alone. Measured 2026-10-20 before the check: all five shapes below
//   built clean, and the parent read the worker's write through the alias the
//   callee kept (a: cache[0].n = 42, b: registry[0].n = 7).
//
// RED MEANS: one of the diagnostics stopped firing.
//
// GUARD-CHECK-FAIL a call with side effects may keep an alias of it: calls 'getShared'
// GUARD-CHECK-FAIL a call with side effects may keep an alias of it: constructs 'Registered'
// GUARD-CHECK-FAIL a call with side effects may keep an alias of it: calls 'stash'
// GUARD-CHECK-FAIL a call with side effects may keep an alias of it: calls 'current'
// GUARD-CHECK-FAIL a call with side effects may keep an alias of it: calls 'pick'

interface Box { n: int32; }
interface Holder { b: Box | null; }

const cache: Box[] = [];
function getShared(): Box { const b: Box = { n: 0 }; cache.push(b); return b; }

// 1 — the factory keeps what it returns.
function fromAliasingFactory(): int32 {
	const g = getShared();
	return await spawn(() => { g.n = 42; return g.n; }, { move: [g] });
}

const registry: Registered[] = [];
class Registered {
	n: int32 = 0;
	constructor() { registry.push(this); }
}

// 2 — the constructor publishes `this`.
function fromPublishingConstructor(): int32 {
	const g = new Registered();
	return await spawn(() => { g.n = 7; return g.n; }, { move: [g] });
}

const kept: Stashed[] = [];
class Stashed {
	n: int32 = 0;
	stash(): void { kept.push(this); }
}

// 3 — a method on the owner stores the receiver.
function afterStashingMethod(): int32 {
	const g = new Stashed();
	g.stash();
	return await spawn(() => { g.n = 9; return g.n; }, { move: [g] });
}

const shared: Box = { n: 0 };
function current(): Box { return shared; }

// 4 — a field initialised from a call that returns module state.
function fieldFromModuleState(): int32 {
	const g: Holder = { b: current() };
	return await spawn(() => { const b = g.b; return b != null ? b.n : 0; }, { move: [g] });
}

const pool: Box[] = [{ n: 0 }];
function pick(): Box { return pool[0]; }

// 5 — a field assigned from a call that reads a module-level array.
function fieldAssignedFromCall(): int32 {
	const g: Holder = { b: null };
	g.b = pick();
	return await spawn(() => { const b = g.b; return b != null ? b.n : 0; }, { move: [g] });
}

console.log(fromAliasingFactory() + fromPublishingConstructor() + afterStashingMethod() + fieldFromModuleState() + fieldAssignedFromCall());
