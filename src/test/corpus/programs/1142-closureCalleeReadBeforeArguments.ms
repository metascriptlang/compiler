// @stdout: field 4
// @stdout: local 3
// @stdout: module 15
// @stdout: nested 4
// TS reads a call's callee before its arguments, so an argument that reassigns
// the closure the callee names changes nothing for this call: the callee value
// was already read. Covers a closure field, a local `let`, a module-level `let`
// rebound by the second of three arguments, and the same through an inner call.

class Box { run: (x: number) => number = (x: number): number => x + 3; }

let shared = (a: number, b: number, c: number): number => a + b + c;

function rebindShared(): number {
	shared = (a: number, b: number, c: number): number => a * b * c * 100;
	return 4;
}

function field(): number {
	const b = new Box();
	return b.run((() => { b.run = (x: number): number => x + 100; return 1; })());
}

function local(): number {
	let h = (x: number, y: number): number => x + y;
	return h(1, (() => { h = (x: number, y: number): number => x * y * 100; return 2; })());
}

function nested(): number {
	let g = (x: number): number => x + 1;
	return g(((): number => { g = (x: number): number => x + 100; return 3; })());
}

console.log("field " + field().toString());
console.log("local " + local().toString());
console.log("module " + shared(4, rebindShared(), 7).toString());
console.log("nested " + nested().toString());
