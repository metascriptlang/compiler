// `move x` of a variable a closure captures is refused, naming the variable
//
// INVARIANT: a captured variable lives in the closure's environment, so an explicit move of it is
//   an implicit copy and `move ident` (the reference's ensureMove) refuses it; emptying the slot
//   would hand the closure null (class) or "" (string). The checker refuses it before lifting,
//   where the identifier and its symbol are intact.
//
// WHAT IT CATCHES: the checker's captured-symbol record or the refusal in checkMoveExpr going
//   missing. Axes: a class and a string, an arrow and a nested function, a `const` and a push argument,
//   a closure declared before and after the move, a generic function and a generic method.
//
// RED MEANS: refuseCapturedMove (src/checker/checkExprPass.ms) stopped firing, or the capture is no
//   longer recorded where the identifier is checked.
//
// GUARD-CHECK-FAIL cannot move 'x': a closure captures it
// GUARD-CHECK-FAIL cannot move 'y': a closure captures it
// GUARD-CHECK-FAIL cannot move 'w': a closure captures it
// GUARD-CHECK-FAIL cannot move 'v': a closure captures it
// GUARD-CHECK-FAIL cannot move 'gx': a closure captures it
// GUARD-CHECK-FAIL cannot move 'gm': a closure captures it

class McBox { name: string; constructor(n: string) { this.name = n; } }
const keep: McBox[] = [];

function classArrow(): string {
	const x = new McBox("x");
	const f = () => x.name;
	keep.push(move x); // GUARD-REFUSED
	return f();
}

function stringNested(): string {
	const y = "y" + keep.length;
	function g(): string { return y; }
	const z = move y; // GUARD-REFUSED
	return g() + z;
}

function classNested(): string {
	const w = new McBox("w");
	function g(): string { return w.name; }
	const moved = move w; // GUARD-REFUSED
	return g() + moved.name;
}

function hoistedAfter(): string {
	const v = "v" + keep.length;
	const moved = move v; // GUARD-REFUSED
	function g(): string { return v; }
	return g() + moved;
}

function genericFn<T>(gx: T): T {
	const read = (): T => gx;
	const moved = move gx; // GUARD-REFUSED
	read();
	return moved;
}

class McHolder<T> {
	run(gm: T): T {
		const moved = move gm; // GUARD-REFUSED
		const read = (): T => gm;
		read();
		return moved;
	}
}

console.log(hoistedAfter() + classArrow() + stringNested() + classNested() + genericFn(new McBox("g")).name + new McHolder<McBox>().run(new McBox("m")).name);
