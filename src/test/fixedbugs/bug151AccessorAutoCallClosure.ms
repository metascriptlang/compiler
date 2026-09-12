// bug151 — an accessor read inside an arrow or a nested function had to be called with `()`
// Symptom: `() => c + 1` and `function inner() { return c * 3; }` were type errors on a captured accessor; an arrow
//          `() => c` returned the closure instead of a fresh read.
// Root cause: same as bug154 — the read is rewritten by the checker, so every body (arrow, function expression,
//             nested declaration) gets it; nothing in lambda lifting had to change (the callee identifier is still
//             the captured variable).
// Fix: see bug154.

type Acc151<T> = distinct (() => T);

function makeSignal151<T>(v: T): [Acc151<T>, (n: T) => void] {
	let cur = v;
	return [(() => cur) as Acc151<T>, (n: T) => { cur = n; }];
}

test "an accessor read inside an arrow tracks the current value" {
	const [c, setC] = makeSignal151<number>(1);
	const g = (): number => c + 1;
	assert g() === 2;
	setC(5);
	assert g() === 6;
}

test "an accessor read inside a nested function tracks the current value" {
	const [c, setC] = makeSignal151<number>(2);
	function outer(): number {
		function inner(): number { return c * 3; }
		return inner();
	}
	assert outer() === 6;
	setC(3);
	assert outer() === 9;
}

test "an arrow returning a bare accessor is a thunk of its value" {
	const [c, setC] = makeSignal151<number>(1);
	const th: () => number = () => c;
	assert th() === 1;
	setC(7);
	assert th() === 7;
}
