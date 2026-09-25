// nim-guard: `move x` into a borrowing parameter records no move
//
// INVARIANT (injectdestructors.nim moveOrCopy: an assignment destroys the old value
//   unless it is a first write or the right side consumed the destination): in
//   `x = f(move x)` with a borrowing parameter nothing consumed `x`, so its old value
//   is destroyed after the store.
//
// WHAT IT CATCHES: processMove recording a move in a Normal (borrowing) position, which
//   makes processAssignment treat `x` as consumed and store raw: the old value leaks.
//   Axes: in a loop, at top level of the body, and a consuming `move` beside them.
//
// RED MEANS: move bookkeeping drifted from where moves happen. Run /trace-nim on
//   processMove and processAssignment (consumedInRhs) in inject.ms.
// GUARD-BALANCE MbBox
// GUARD-JS

class MbBox { s: string; constructor(s: string) { this.s = s; } }

function grow(b: MbBox): MbBox { return new MbBox(b.s + "+"); }
function look(b: MbBox): int32 { return b.s.length; }

function run(): string {
	let x = new MbBox("a");
	for (let i: int32 = 0; i < 3; i += 1) { x = grow(move x); }
	const n = look(move x);
	const y = move x;
	let z = new MbBox("z");
	z = grow(move z);
	return y.s + n + z.s;
}

if (run() == "a+++4z+") {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
