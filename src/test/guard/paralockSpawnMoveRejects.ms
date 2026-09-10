// nim-guard: spawn { move } — the parent loses the moved binding, and the
//   option surface is closed.
//
// INVARIANT (PARALOCK Amendment M): spawn(fn, { move: [x] }) transfers x into
//   the thunk on the parent thread at the spawn site; every later use of x in
//   the parent is an error, entries must be plain local names, and an unknown
//   option key is an error rather than a silent no-op.
//
// WHAT IT CATCHES: the move list degrading back into the pre-M state, where
//   `{ move: [c] }` built clean and ran as a borrow (measured 2026-09-10 on the
//   HEAD binary: rc=0, the thunk saw the parent's object).
//
// RED MEANS: one of the four diagnostics stopped firing.
//
// GUARD-CHECK-FAIL was moved into a spawn thunk
// GUARD-CHECK-FAIL entries must be plain local names
// GUARD-CHECK-FAIL unknown spawn option 'moove'
// GUARD-CHECK-FAIL cannot move out of Readonly<

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
