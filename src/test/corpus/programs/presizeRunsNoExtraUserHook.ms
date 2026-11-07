// @stdout: true 3
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: an array of structs with a user destroy hook built by a push loop runs the hook as many times as the same build
// the presize pass leaves alone (a conditional push), so no zeroed slot reaches the hook.

struct P { v: int32; }

let destroyed: int32 = 0;

function onDestroy(this p: P): void { destroyed += 1; }

function pushed(a: int32[]): int32 {
	const out: P[] = [];
	for (const x of a) out.push({ v: x } as P);
	return out.length;
}

function conditional(a: int32[]): int32 {
	const out: P[] = [];
	for (const x of a) {
		if (x > 0) out.push({ v: x } as P);
	}
	return out.length;
}

const a: int32[] = [1, 2, 3];
let before = destroyed;
const n = pushed(a);
const p = destroyed - before;
before = destroyed;
conditional(a);
const c = destroyed - before;
console.log(p == c, n);
