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
// GUARD-CHECK-FAIL cannot write through Readonly<
// GUARD-CHECK-FAIL PARALOCK E24
// GUARD-CHECK-FAIL mutates its receiver
// GUARD-CHECK-FAIL got Readonly<Counter>, expected Counter
// GUARD-CHECK-FAIL cannot move out of Readonly<
// GUARD-CHECK-FAIL cannot pass an 'out' argument through Readonly<
// GUARD-CHECK-FAIL cannot cast away Readonly<
// GUARD-CHECK-FAIL cannot call 'bump' on Readonly<Tally>

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

// 6 — a spawn nested in a spawn: the inner thunk's own check reports it, once.
function nestedSpawnWrite(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => {
		const g = spawn(() => { c.n = 2; return c.n; });
		return await g;
	});
	return await f;
}

// 7 — alias: the view follows the value, not the name.
function aliasWrite(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => { const a = c; a.n = a.n + 1; return a.n; });
	return await f;
}

// 8 — loop binding over a captured array.
function loopBindingWrite(): int32 {
	const arr: Counter[] = [{ n: 0 }];
	const f = spawn(() => { for (const x of arr) { x.n = 5; } return arr[0].n; });
	return await f;
}

// 9 — destructuring from a captured ref.
function destructureWrite(): int32 {
	const h: Boxed = { box: { n: 0 } };
	const f = spawn(() => { const { box } = h; box.n = 3; return box.n; });
	return await f;
}

// 10 — a builtin mutator is a write.
function pushWrite(): int32 {
	const arr: int32[] = [];
	const f = spawn(() => { arr.push(1); return arr.length; });
	return await f;
}

// 11 — a callee that wants the mutable type cannot receive the view.
function bump(c: Counter): void { c.n = c.n + 1; }
function calleeWrite(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => { bump(c); return c.n; });
	return await f;
}

// 12 — a struct copy still carries the refs inside it.
struct Slot { c: Counter; }
interface Rack { slot: Slot; }
function structCopyWrite(): int32 {
	const r: Rack = { slot: { c: { n: 0 } } };
	const f = spawn(() => { const s = r.slot; s.c.n = 9; return 0; });
	return await f;
}

// 13 — an array literal cannot launder the view into a mutable element type.
function arrayLiteralWrite(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => { const xs: Counter[] = [c]; xs[0].n = 9; return 0; });
	return await f;
}

// 14 — a class method needs a mutable receiver.
class Tally { n: int32 = 0; bump(): void { this.n = this.n + 1; } }
function methodWrite(): int32 {
	const t = new Tally();
	const f = spawn(() => { t.bump(); return t.n; });
	return await f;
}

// 15 — `as` does not cast the view away.
function castWrite(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => { const m = c as Counter; m.n = 9; return 0; });
	return await f;
}

// 16 — moving out of a borrow is a write to the parent's slot.
interface MoveBox { c: Counter; }
function moveOut(): int32 {
	const b: MoveBox = { c: { n: 0 } };
	const f = spawn(() => { const t = move b.c; return t.n; });
	return await f;
}

// 17 — an `out` argument is a write.
interface OutCell { k: int32; }
function fill(out r: int32): void { r = 7; }
function outWrite(): int32 {
	const cell: OutCell = { k: 0 };
	const f = spawn(() => { fill(out cell.k); return 0; });
	return await f;
}
