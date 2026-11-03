// @stdout: 10 11 12 13 | a0 a1 a2 | a1 | a1 | a1 | a1

let gl: number[] = [10, 11, 12, 13];

function swap(): void {
	gl = [90, 91, 92, 93];
}

function forOfNumbers(ref xs: number[]): string {
	const seen: number[] = [];
	for (const x of xs) {
		if (x == 10) swap();
		seen.push(x);
	}
	return seen.join(" ");
}

let names: string[] = ["a0", "a1", "a2"];

function rename(): void {
	names = ["n0", "n1", "n2"];
}

function reset(): void {
	names = ["a0", "a1", "a2"];
}

function forOfStrings(ref xs: string[]): string {
	const seen: string[] = [];
	for (const x of xs) {
		if (x == "a0") rename();
		seen.push(x);
	}
	return seen.join(" ");
}

function heldInLocal(ref xs: string[]): string {
	const it = xs;
	rename();
	return it[1];
}

function readElement(a: string[]): string {
	rename();
	return a[1];
}

function passedBorrowed(ref xs: string[]): string {
	return readElement(xs);
}

function elementInLocal(ref xs: string[]): string {
	const s = xs[1];
	rename();
	return s;
}

class Box {
	items: string[] = ["a0", "a1", "a2"];
}

const box = new Box();

function refill(): void {
	box.items = ["n0", "n1", "n2"];
}

function fieldHeldInLocal(ref xs: string[]): string {
	const it = xs;
	refill();
	return it[1];
}

const a = forOfNumbers(gl);
const b = forOfStrings(names);
reset();
const c = heldInLocal(names);
reset();
const d = passedBorrowed(names);
reset();
const e = elementInLocal(names);
const f = fieldHeldInLocal(box.items);
console.log(`${a} | ${b} | ${c} | ${d} | ${e} | ${f}`);
