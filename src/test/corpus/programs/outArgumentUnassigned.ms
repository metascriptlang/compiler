// @stdout: rows=22 wrong=0
// note: a local declared without an initializer and filled by passing it as an `out` argument holds what the callee wrote, for scalars, a string, a value struct, a sized array and a class reference, with and without the `out` keyword at the call, in a loop, a branch, a closure, an async function and a generator; an `out` argument may also name a field or an element. Each row prints only when it is wrong.

class Cell {
	v: int32 = 0;
}
struct Pt {
	x: int32;
	y: int32;
}

let rows: int32 = 0;
let wrong: int32 = 0;
function show(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) {
		wrong += 1;
		console.log(`${name}: got ${got} want ${want}`);
	}
}

function setInt(out a: int32, v: int32): void { a = v; }
function setBig(out a: int64): void { a = 5; }
function setFloat(out a: float64): void { a = 2.5; }
function setBool(out a: boolean): void { a = true; }
function setStr(out a: string): void { a = "hi"; }
function setPt(out p: Pt): void { p = { x: 1, y: 2 }; }
function setSized(out a: int32[4]): void { a = [0, 7, 0, 2]; }
function setSizedPts(out a: Pt[2]): void { a = [{ x: 0, y: 0 }, { x: 0, y: 4 }]; }
function setCell(out c: Cell | null): void { const n = new Cell(); n.v = 3; c = n; }
function setTwo(out a: int32, out b: string): void { a = 5; b = "x"; }
function setPassed(out a: int32): void { setInt(out a, 6); }
function setGeneric<T>(out a: T, v: T): void { a = v; }

function scalars(): string {
	let a: int32;
	let b: int64;
	let c: float64;
	let d: boolean;
	setInt(out a, 5);
	setBig(out b);
	setFloat(out c);
	setBool(out d);
	return `${a} ${b + 1} ${c} ${d}`;
}

function text(): string {
	let s: string;
	setStr(out s);
	return s;
}

function structValue(): string {
	let p: Pt;
	setPt(out p);
	return `${p.x} ${p.y}`;
}

function sized(): string {
	let a: int32[4];
	setSized(out a);
	return `${a[0]} ${a[1]} ${a[3]}`;
}

function sizedStructs(): string {
	let a: Pt[2];
	setSizedPts(out a);
	return `${a[0].x} ${a[1].y}`;
}

function classRef(): string {
	let c: Cell | null;
	setCell(out c);
	return `${c!.v}`;
}

function bare(): string {
	let a: int32;
	setInt(a, 5);
	return `${a}`;
}

function two(): string {
	let a: int32;
	let b: string;
	setTwo(out a, out b);
	return b + a;
}

function twice(): string {
	let a: int32;
	setInt(out a, 1);
	const first = a;
	setInt(out a, 2);
	return `${first}${a}`;
}

function inLoop(): string {
	let outer: int32;
	let sum = 0;
	for (let i = 0; i < 3; i += 1) {
		let inner: int32;
		setInt(out inner, i + 1);
		setInt(out outer, inner * 10);
		sum += outer;
	}
	return `${sum}`;
}

function inBranch(c: boolean): string {
	let a: int32;
	if (c) { setInt(out a, 5); } else { a = 1; }
	return `${a}`;
}

function closureBefore(): string {
	let a: int32;
	const read = (): int32 => a;
	setInt(out a, 5);
	return `${read()}`;
}

function closureAfter(): string {
	let a: int32;
	setInt(out a, 5);
	const bump = (): void => { a = a + 1; };
	bump();
	return `${a}`;
}

function viaParameter(p: int32): string {
	setInt(out p, 5);
	return `${p}`;
}

function passedOn(): string {
	let a: int32;
	setPassed(out a);
	return `${a}`;
}

function generic(): string {
	let s: string;
	let n: int32;
	setGeneric(out s, "g");
	setGeneric(out n, 4);
	return s + n;
}

function fieldAndElement(): string {
	const c = new Cell();
	const xs: int32[] = [1, 2, 3];
	setInt(out c.v, 5);
	setInt(out xs[1], 6);
	return `${c.v} ${xs[1]}`;
}

function* numbers(): Iterator<int32> {
	let a: int32;
	setInt(out a, 5);
	yield a;
}

async function later(): Promise<int32> {
	let a: int32;
	setInt(out a, 5);
	return a;
}

let moduleInt: int32;
let moduleText: string;
setInt(out moduleInt, 5);
setStr(out moduleText);

show("scalars", scalars(), "5 6 2.5 true");
show("string", text(), "hi");
show("struct value", structValue(), "1 2");
show("sized array", sized(), "0 7 2");
show("sized structs", sizedStructs(), "0 4");
show("class reference", classRef(), "3");
show("bare identifier", bare(), "5");
show("two outs", two(), "x5");
show("same variable twice", twice(), "12");
show("loop", inLoop(), "60");
show("branch taken", inBranch(true), "5");
show("branch skipped", inBranch(false), "1");
show("closure reads", closureBefore(), "5");
show("closure writes", closureAfter(), "6");
show("parameter", viaParameter(0), "5");
show("passed on", passedOn(), "6");
show("generic", generic(), "g4");
show("field and element", fieldAndElement(), "5 6");
show("module int", `${moduleInt}`, "5");
show("module string", moduleText, "hi");
for (const v of numbers()) { show("generator", `${v}`, "5"); }

async function main(): Promise<void> {
	show("async", `${await later()}`, "5");
	console.log(`rows=${rows} wrong=${wrong}`);
}
main();
