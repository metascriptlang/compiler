// nim-guard: assignment into a cursor destination is a plain assignment
//
// INVARIANT (injectdestructors.nim p(), nkAsgn arm: moveOrCopy runs only when
//   `not isCursor(n[0])`; a cursor destination takes `p(n[1], c, s, normal)`):
//   the right-hand side of `cursor = rhs` is read, never consumed. A fresh
//   value is captured and destroyed at scope exit like any discarded result;
//   a borrowed one is not incref'd, because the cursor never releases it.
//
// WHAT IT CATCHES: processAssignment handing a cursor LHS's RHS to Consumed
//   mode. Rebind: `for (let b of xs) { b = new CaBox(..) }` sinks the fresh box
//   into a slot nobody destroys (3 CaBox leak). Conditional iterable: the
//   for-of `$iter` cursor receives a sink temp whose incref is never paid back.
//
// RED MEANS: the cursor model drifted from Nim. Run /trace-nim on
//   processAssignment and moveOrCopy in inject.ms.
// GUARD-BALANCE CaBox
// GUARD-BALANCE msRefArrayRefCell
// GUARD-JS

class CaBox { v: int32; constructor(v: int32) { this.v = v; } }

function lastRebound(xs: CaBox[]): int32 {
	let out = 0;
	for (let b of xs) { b = new CaBox(b.v * 10); out = b.v; }
	return out;
}

function keptRebound(xs: CaBox[]): CaBox | null {
	let kept: CaBox | null = null;
	for (let b of xs) { b = new CaBox(b.v + 1); kept = b; }
	return kept;
}

function pickedSum(flag: boolean, a: CaBox[], b: CaBox[]): int32 {
	let n = 0;
	for (const x of (flag ? a : b)) { n += x.v; }
	return n;
}

function run(): int32 {
	const xs = [new CaBox(1), new CaBox(2), new CaBox(3)];
	const ys = [new CaBox(7)];
	const k = keptRebound(xs);
	const got = lastRebound(xs) + (k != null ? k.v : 0) + pickedSum(true, xs, ys) + pickedSum(false, xs, ys);
	return got;
}

if (run() == 30 + 4 + 6 + 7) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
