// nim-guard: a spawn thunk may read what it borrows, never write it
//
// INVARIANT (PARALOCK Amendment L, §9.2 E24 + E147, I23): a value entering a
//   spawn thread is one of the four boundary verbs. A plain captured ref is a
//   BORROW — legal because the parent joins before the lender dies — and a
//   borrow is read-only. Writing through it is not a verb: mutable shared state
//   has exactly one sanctioned form (I22, Locked<T>), reached through the
//   lockedUpdate / lockedRead callback, which E147 exempts.
//
// WHAT IT CATCHES: the write ban silently dropped, or re-anchored back to
//   `this` (the shape it had before Amendment L, when the identical write on a
//   non-actor local compiled clean on both backends).
//
//   The measured cost of dropping it is not a race that might not fire — it is
//   two backends disagreeing with no diagnostic:
//     const c: Counter = { n: 0 };
//     const inner = await spawn(() => { c.n = c.n + 1; return c.n; });
//     --target=c        inner=1 outer=1   (shared pointer)
//     --target=raiser   inner=1 outer=0   (copied into the child strand's heap)
//   Amendment J records that divergence as deliberate and unobservable; it is
//   only observable through a write this file forbids.
//
// KNOWN GAP (Amendment L, deliberate): the check is a write-site check, so a
//   write performed by a callee on a captured ref passed to it is NOT caught —
//   the shipped actor half (S3/E62) has the same blind spot. Closing it needs
//   writability in the signature. Nothing here pretends otherwise.
//
// RED MEANS: the write ban stopped firing. Amendment J's "the same programs
//   compile, the same E-cases error" no longer holds, and the C-versus-Raiser
//   divergence is reachable from source again.
//
// The legal half — a read-only borrow, and a write inside a Locked critical
// section — is pinned by paralockSpawnBorrows.ms, which must build and run.
//
// GUARD-CHECK-FAIL is read-only inside a spawn thunk
// GUARD-CHECK-FAIL PARALOCK E24/E147

interface Counter { n: int32; }

interface Boxed { box: Counter; }

// 1 — direct field write through a captured ref.
function directWrite(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => { c.n = c.n + 1; return c.n; });
	return await f;
}

// 2 — compound assignment, same chain root.
function compoundWrite(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => { c.n += 1; return c.n; });
	return await f;
}

// 3 — increment write-back.
function incrementWrite(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => { c.n++; return c.n; });
	return await f;
}

// 4 — element write through a captured array.
function elementWrite(): int32 {
	const arr: int32[] = [0, 0];
	const f = spawn(() => { arr[0] = 7; return arr[0]; });
	return await f;
}

// 5 — nested chain: the root is still the captured binding.
function nestedChainWrite(): int32 {
	const h: Boxed = { box: { n: 0 } };
	const f = spawn(() => { h.box.n = 1; return h.box.n; });
	return await f;
}
