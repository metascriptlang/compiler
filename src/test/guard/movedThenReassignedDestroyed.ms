// nim-guard: a variable moved and then assigned again is still destroyed at scope end
//
// INVARIANT (optimizer.nim analyse, nkSym arm :155-159): a wasMoved(x)/destroy(x)
//   pair is elided only when nothing between them uses x. Any use of the
//   location, an assignment included (nkAsgn analyses its target, :165-168),
//   cancels the pairing, so the value x holds at scope end is released.
//   NIM-REF: AN-12 (only optimize.ms may elide a destroy), SAME.
//
// WHAT IT CATCHES: optimizeBlock letting its moved set only grow. `out.push(cur)`
//   moves cur (wasMoved), `cur = new Box(..)` stores a fresh box, and the
//   scope-end destroy(cur) was dropped as if cur were still zeroed: one Box
//   leaked per call. Shapes: straight line, a loop of calls, and an if/else
//   whose branches both move and then reassign (the branch-intersection path).
//
// RED MEANS: the wasMoved/destroy elision drifted from Nim. Run /trace-nim on
//   scanBlock and collectIfMoved in analyzer/optimize.ms.
// GUARD-BALANCE Box
// GUARD-JS

class Box { v: string; constructor(v: string) { this.v = v; } }

let seen = 0;

function build(out: Box[], i: int32): void {
	let cur = new Box("a" + String(i));
	out.push(cur);
	cur = new Box("b" + String(i));
	seen += cur.v.length;
}

function viaLocal(): void {
	let b = new Box("a" + String(1));
	let hold: Box | null = null;
	hold = b;
	b = new Box("b" + String(2));
	seen += b.v.length;
}

function bothBranches(flag: boolean, out: Box[]): void {
	let cur = new Box("c" + String(flag));
	if (flag) {
		out.push(cur);
		cur = new Box("t");
	} else {
		out.push(cur);
		cur = new Box("f");
	}
	seen += cur.v.length;
}

function run(): int32 {
	const out: Box[] = [];
	for (let i = 0; i < 100; i++) build(out, i);
	viaLocal();
	bothBranches(true, out);
	bothBranches(false, out);
	return out.length;
}

if (run() == 102 && seen == 290 + 2 + 2) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
