// nim-guard: a lock opens its own payload and nothing else
//
// INVARIANT (PARALOCK Amendment N, I22 + I23): shared mutable state exists
//   only as the payload of a Locked<T> cell. Inside a lockedUpdate / lockedRead
//   callback the payload parameter is writable; every binding the spawn thunk
//   captured is still Readonly<T>. The reference's guardDotAccess (sempass2)
//   has the same shape: holding a lock licenses the locations it guards.
//
// WHAT IT CATCHES: the callback turned back into a write licence for captures
//   (Amendment L's E147). Measured before the fix: two thunks, each with its
//   own gate, incrementing one captured counter 100000 times each returned
//   165668 on C drc, TSan reported the race, and the checker said nothing.
//
// RED MEANS: a write to a capture inside a lock callback compiles again, so a
//   lock that guards nothing silences the spawn write ban.
//
// The legal half, a write to the payload, is pinned by paralockSpawnBorrows.ms.
//
// GUARD-CHECK-FAIL cannot write through Readonly<

interface Counter { n: int32; }

// 1 — a gate made inside the thunk guards nothing the parent owns.
function privateGate(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => {
		const gate = new Locked<int32>(0);
		lockedUpdate(gate, (v: int32): int32 => { c.n = c.n + 1; return v; });
		return 0;
	});
	await f;
	return c.n;
}

// 2 — a shared gate still does not own the captured counter.
function sharedGate(): int32 {
	const gate = new Locked<int32>(0);
	const c: Counter = { n: 0 };
	const f = spawn(() => {
		lockedUpdate(gate, (v: int32): int32 => { c.n = c.n + 1; return v + 1; });
		return 0;
	});
	await f;
	return c.n;
}

// 3 — a read section is not a write licence.
function readSection(): int32 {
	const gate = new Locked<int32>(0);
	const c: Counter = { n: 0 };
	const f = spawn(() => {
		return lockedRead(gate, (v: int32): int32 => { c.n = v + 1; return c.n; });
	});
	return await f;
}

// 4 — a builtin mutator on a capture inside the callback.
function pushUnderGate(): int32 {
	const gate = new Locked<int32>(0);
	const items: int32[] = [];
	const f = spawn(() => {
		lockedUpdate(gate, (v: int32): int32 => { items.push(9); return v; });
		return 0;
	});
	await f;
	return items.length;
}

function main(): int32 {
	return privateGate() + sharedGate() + readSection() + pushUnderGate();
}

process.exit(main());
