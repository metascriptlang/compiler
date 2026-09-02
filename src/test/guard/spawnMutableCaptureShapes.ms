// nim-guard: the spawn mutable-capture rule must reach EVERY capture shape
//
// INVARIANT (PARALOCK §5.3, capture table row 2: `let x` from an outer scope is
//   "No — compile error: mutable capture forbidden in spawn"; NOT S4, which was
//   dropped in §7.3 as a Rust borrow-checker concept with no actor precedent —
//   this rule is about the capture itself, not about parent mutation between
//   spawn and await): a spawn thunk BORROWS the enclosing closure
//   env — the lifted thunk is handed `_env_main_` itself, not a copy (verified
//   in the emitted C: `$borrow_0_ = _env_main_; msIncref($borrow_0_)` right
//   before msSpawnSlotSubmit). A captured MUTABLE binding is therefore one
//   memory cell shared with the parent thread: the worker's read races a later
//   parent write, and a worker write lands in the parent's slot. Only a closure
//   created inside a loop body gets a per-iteration env copy (`$lit5_->iter =
//   _env_main_->iter`), which is why a `for (let i…)` capture is a snapshot and
//   nothing else is. So the rule is not stylistic: it is the only thing
//   standing between a `let` capture and a data race.
//
// WHAT IT CATCHES: the rule firing on only a few hand-listed node shapes. Until
//   2026-09-03 walkForMutableCaptures hand-listed its arms with a silent `_ => {}`
//   default, so THREE racing programs compiled clean and ran:
//     - `sq(k)` with `k: int32` — the argument is wrapped in HiddenStdConv
//       (int32→number), which the arm list did not peel. Measured: worker read
//       the parent's post-spawn write (k=100 → r=10000).
//     - `x++` — UpdateExpr, no arm at all. Measured: the worker's increment
//       landed in the parent's slot (x=2 after the await).
//     - a read inside a C-style `for` in the thunk — ForStmt had no arm, so the
//       whole loop body was unvisited.
//   The fix delegates the default arm to forEachChild (one traversal source of
//   truth) and keeps explicit no-ops for BINDING positions only.
//
// RED MEANS: either the walk lost its forEachChild default (a capture shape is
//   silently unchecked again — race back), or the diagnostic was retagged.
//   Retag only with a PARALOCK amendment.
//
// Proven red 2026-09-03: the pre-fix compiler builds this file CLEAN on all
// three shapes, i.e. it ships the three races above.
//
// GUARD-CHECK-FAIL mutable variable 'mk' cannot be captured by spawn
// GUARD-CHECK-FAIL mutable variable 'mu' cannot be captured by spawn
// GUARD-CHECK-FAIL mutable variable 'mb' cannot be captured by spawn

interface MBox { n: int32; }

function sq(n: number): number { return n * n; }

// Shape 1 — read through a HiddenStdConv wrapper (int32 argument → number param).
function hiddenConvRead(): number {
	let mk: int32 = 3;
	const h = spawn(() => sq(mk));
	mk = 100;
	return await h;
}

// Shape 2 — write-back from the worker into the parent's env slot.
function updateWriteBack(): int32 {
	let mu = 1;
	const h = spawn(() => { mu++; return 0; });
	const r = await h;
	return mu + r;
}

// Shape 3 — read inside a C-style `for` in the thunk body (loop stmt traversal).
function loopBodyRead(): int32 {
	let mb: MBox = { n: 1 };
	const h = spawn(() => {
		let s = 0;
		for (let i = 0; i < 10; i++) { s = s + mb.n; }
		return s;
	});
	mb.n = 2;
	return await h;
}

console.log(hiddenConvRead());
console.log(updateWriteBack());
console.log(loopBodyRead());
