// nim-guard: an `out` argument passed over a variable that already holds a value releases that value
//
// INVARIANT (injectdestructors.nim genSink): the callee's first write to an `out` parameter is a
//   bitwise store only when the destination is an analysable access; a write through the parameter's
//   deref is not, so it is `=sink`, which destroys the old value. The caller's old value dies there.
//
// WHAT IT CATCHES: the first write to an `out` parameter compiled as a declaration blit: every
//   call over a live variable leaked the old object. Axes: a local, a field of a local, an element,
//   a method's out parameter, and a variable holding nothing (no old value to release).
//
// RED MEANS: processAssignment marks a HiddenDeref target as a first write again. Run /trace-nim
//   on the HiddenDeref arm of processAssignment in inject.ms and isAnalysableFieldAccess in alias.ms.
// GUARD-BALANCE OaBox
// GUARD-JS

class OaBox { n: int32; constructor(n: int32) { this.n = n; } }
class OaHolder {
	b: OaBox;
	constructor() { this.b = new OaBox(0); }
	fill(out dst: OaBox, n: int32): void { dst = new OaBox(n); }
}

function setLocal(out b: OaBox, n: int32): void { b = new OaBox(n); }

function run(): int32 {
	let sum: int32 = 0;
	for (let i: int32 = 0; i < 50; i += 1) {
		let y = new OaBox(i);
		setLocal(out y, i + 1);
		sum += y.n;
		const h = new OaHolder();
		setLocal(out h.b, i + 2);
		sum += h.b.n;
		const arr: OaBox[] = [new OaBox(i)];
		setLocal(out arr[0], i + 3);
		sum += arr[0].n;
		let z = new OaBox(i);
		h.fill(out z, i + 4);
		sum += z.n;
	}
	let fresh: OaBox;
	setLocal(out fresh, 7);
	return sum + fresh.n;
}

if (run() == 5407) {
	console.log("GUARD-OK");
} else {
	console.log("FAIL " + run());
	process.exit(1);
}
