// @stdout: 5 9 -1 -1 -1 -2 5
// note: a constant declared from a call returning a struct with owned fields receives the result in place; a call that raises before writing it, one that raises from a finally after writing it, and a caller finally that raises while the constant is live each release what was written exactly once. Same output on every lane.
struct Parsed { name: string; tags: string[]; }

let earlyFail = false;
let lateFail = false;

function parse(s: string): Parsed {
	if (earlyFail) throw new Error("early");
	try {
		return { name: s + "!", tags: [s + "?"] };
	} finally {
		if (lateFail) throw new Error("late");
	}
}
function size(s: string): number {
	const p = parse(s);
	return p.name.length + p.tags.length;
}
function sizes(n: number): number {
	let total = 0;
	for (let i = 0; i < n; i++) {
		const p = parse(`${i}`);
		total += p.name.length + p.tags.length;
	}
	return total;
}
function guarded(s: string): number {
	try {
		return size(s);
	} catch (e) {
		return -1;
	}
}
function guardedSizes(n: number): number {
	try {
		return sizes(n);
	} catch (e) {
		return -1;
	}
}
function finallyRaises(s: string): number {
	const p = parse(s);
	try {
		return p.name.length;
	} finally {
		if (p.tags.length > 0) throw new Error("finally");
	}
}
function guardedFinally(s: string): number {
	try {
		return finallyRaises(s);
	} catch (e) {
		return -2;
	}
}

const first = size("abc");
const loop = sizes(3);
lateFail = true;
const late = guarded("abc");
const lateLoop = guardedSizes(3);
lateFail = false;
earlyFail = true;
const early = guarded("abc");
earlyFail = false;
console.log(`${first} ${loop} ${late} ${lateLoop} ${early} ${guardedFinally("abc")} ${guarded("abc")}`);
