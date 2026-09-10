// nim-guard: spawn { move } — the parent loses the moved binding, and the
//   option surface is closed.
//
// INVARIANT (PARALOCK Amendment M): spawn(fn, { move: [x] }) transfers x into
//   the thunk on the parent thread at the spawn site; every later use of x in
//   the parent is an error, entries must be plain local names, and an unknown
//   option key is an error rather than a silent no-op. A moved binding must be
//   the sole owner (E148): bound and rebound only from fresh values, never
//   aliased into another binding, field, literal, call, closure or defer
//   before the spawn, never a parameter, a for..of element or a module-level
//   binding.
//
// WHAT IT CATCHES: the move list degrading back into the pre-M state, where
//   `{ move: [c] }` built clean and ran as a borrow (measured 2026-09-10 on the
//   HEAD binary: rc=0, the thunk saw the parent's object); and the sole-owner
//   rule degrading to the 81179fe9 state, where `const a = c` before the move
//   built clean and the parent read the thunk's write through `a` (v=7 a=7).
//
// RED MEANS: one of the diagnostics stopped firing.
//
// GUARD-CHECK-FAIL was moved into a spawn thunk
// GUARD-CHECK-FAIL entries must be plain local names
// GUARD-CHECK-FAIL unknown spawn option 'moove'
// GUARD-CHECK-FAIL cannot move out of Readonly<
// GUARD-CHECK-FAIL it is bound to 'a'
// GUARD-CHECK-FAIL is not a fresh value
// GUARD-CHECK-FAIL a closure captures it
// GUARD-CHECK-FAIL it is passed to 'register'
// GUARD-CHECK-FAIL it is a parameter
// GUARD-CHECK-FAIL the value assigned into 'c'
// GUARD-CHECK-FAIL a defer that runs after the move uses it
// GUARD-CHECK-FAIL for..of binds it
// GUARD-CHECK-FAIL module-level binding
// GUARD-CHECK-FAIL it is stored in an object literal
// GUARD-CHECK-FAIL the argument passed into 'bag.items.push'

interface Counter { n: int32; }
interface Box { c: Counter; }

// 1 — use after move.
function useAfterMove(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
	const v = await f;
	return v + c.n;
}

// 2 — a field is not a binding.
function moveField(): int32 {
	const b: Box = { c: { n: 0 } };
	const f = spawn(() => { return 0; }, { move: [b.c] });
	return await f;
}

// 3 — unknown option key.
function unknownOption(): int32 {
	const f = spawn(() => { return 1; }, { moove: 1 });
	return await f;
}

// 4 — `move` inside the thunk is still a write to the parent's slot.
function moveInsideThunk(): int32 {
	const b: Box = { c: { n: 0 } };
	const f = spawn(() => { const t = move b.c; return t.n; });
	return await f;
}

interface Reg { cur: Counter; }
interface Bag { items: Counter[]; }
function register(r: Reg, c: Counter): void { r.cur = c; }
const moduleCounter: Counter = { n: 0 };

// 5 — aliased into another binding before the move.
function aliasLocal(): int32 {
	const c: Counter = { n: 0 };
	const a = c;
	const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
	return await f + a.n;
}

// 6 — bound from a field: the container still holds it.
function boundFromField(): int32 {
	const reg: Reg = { cur: { n: 0 } };
	const c = reg.cur;
	const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
	return await f + reg.cur.n;
}

// 7 — a closure created before the move keeps a handle.
function closureAlias(): int32 {
	const c: Counter = { n: 0 };
	const peek = (): int32 => c.n;
	const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
	return await f + peek();
}

// 8 — passed to a call that may store it.
function callArgEscape(): int32 {
	const reg: Reg = { cur: { n: 0 } };
	const c: Counter = { n: 0 };
	register(reg, c);
	const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
	return await f + reg.cur.n;
}

// 9 — a parameter: the caller still owns it.
function moveParam(c: Counter): int32 {
	const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
	return await f;
}

// 10 — rebound from a shared value inside a loop that moves again.
function loopRebind(): int32 {
	const reg: Reg = { cur: { n: 0 } };
	let c: Counter = { n: 0 };
	let total = 0;
	for (let i = 0; i < 2; i += 1) {
		const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
		total += await f;
		c = reg.cur;
	}
	return total;
}

// 11 — a defer runs on the parent after the move.
function deferAlias(): int32 {
	const c: Counter = { n: 0 };
	defer console.log("n=" + c.n);
	const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
	return await f;
}

// 12 — a for..of element: the array still holds it.
function forOfElement(list: Counter[]): int32 {
	let total = 0;
	for (const c of list) {
		const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
		total += await f;
	}
	return total;
}

// 13 — a module-level binding is reachable from every function.
function moveModuleLevel(): int32 {
	const f = spawn(() => { moduleCounter.n = 1; return moduleCounter.n; }, { move: [moduleCounter] });
	return await f;
}

// 14 — stored in an object literal before the move.
function objectLiteralStore(): int32 {
	const c: Counter = { n: 0 };
	const box: Box = { c: c };
	const f = spawn(() => { c.n = 1; return c.n; }, { move: [c] });
	return await f + box.c.n;
}

// 15 — a shared value pushed into the owner's graph before the move.
function pushSharedIntoOwner(): int32 {
	const shared: Counter = { n: 0 };
	const bag: Bag = { items: [] };
	bag.items.push(shared);
	const f = spawn(() => { bag.items[0].n = 1; return bag.items.length; }, { move: [bag] });
	return await f + shared.n;
}
