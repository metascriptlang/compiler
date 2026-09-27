// nim-guard: a write inside a loop is never the first write of a variable declared outside it
//
// INVARIANT (sempass2.nim initVar: nfFirstWrite only when the assignment sits in the
//   block that declared the variable; injectdestructors.nim genSink reads it): after
//   `let b: T;`, an assignment inside a nested loop destroys the old value, because the
//   back edge reaches it with the previous iteration's value.
//
// WHAT IT CATCHES: a first-write flag set by the first assignment met in source order,
//   which turns the loop's store into a raw assignment and leaks every earlier value.
//   Axes: for, while with if/else writes, for-of, do-while, a write after the loop,
//   and a variable declared inside the loop body (a real first write each iteration).
//
// RED MEANS: first-write elision drifted from Nim. Run /trace-nim on processAssignment
//   (isFirstWrite) in inject.ms.
// GUARD-BALANCE FwBox
// GUARD-JS

class FwBox { v: string; constructor(v: string) { this.v = v; } }

function viaFor(n: int32): string {
	let b: FwBox;
	let last = "";
	for (let i: int32 = 0; i < n; i += 1) { b = new FwBox("f" + i); last = b.v; }
	return last;
}

function viaWhileBranches(): string {
	let b: FwBox;
	let last = "";
	let i: int32 = 0;
	while (i < 4) {
		if (i % 2 == 0) { b = new FwBox("e" + i); } else { b = new FwBox("o" + i); }
		last = b.v;
		i += 1;
	}
	return last;
}

function viaForOf(xs: int32[]): string {
	let b: FwBox;
	let last = "";
	for (const x of xs) { b = new FwBox("x" + x); last = b.v; }
	return last;
}

function viaDoWhile(): string {
	let b: FwBox;
	let i: int32 = 0;
	do { b = new FwBox("d" + i); i += 1; } while (i < 3);
	return b.v;
}

function afterLoop(): string {
	let b: FwBox;
	for (let i: int32 = 0; i < 2; i += 1) { b = new FwBox("l" + i); }
	b = new FwBox("after");
	return b.v;
}

function declaredInBody(): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 3; i += 1) {
		let b: FwBox;
		b = new FwBox("in" + i);
		total += b.v.length;
	}
	return total;
}

const got = viaFor(3) + viaWhileBranches() + viaForOf([1, 2, 3]) + viaDoWhile() + afterLoop() + declaredInBody();
if (got == "f2o3x3d2after9") {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
