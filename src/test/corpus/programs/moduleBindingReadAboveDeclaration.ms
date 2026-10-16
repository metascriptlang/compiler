// @stdout: blocked=yes 42 42 abc 8 10 3 42 42
// note: a module let or const without a type annotation, read inside a function, closure or method declared above it, has its initializer's type on every lane: a boolean test, numbers, a string, a struct, a class, an array, an object literal, a closure value and an assignment.

struct Box { n: int32; }

class Cell { n: int32 = 9; }

class Ev {
	prevented: boolean = false;
	preventDefault(): void { this.prevented = true; }
}

class Shower {
	box(): int32 { return BOX.n + 1; }
}

function listen(handler: (e: Ev) => void): boolean {
	const e = new Ev();
	handler(e);
	return e.prevented;
}

function blocked(): string {
	return listen((e: Ev): void => {
		if (block) { e.preventDefault(); }
	}) ? "blocked=yes" : "blocked=no";
}

function makeBox(): Box { return { n: 7 }; }

function bump(): void { count = count + 1; }

function report(): string {
	const cell = (): int32 => CELL.n + 1;
	const parts: string[] = [
		blocked(),
		`${LATER + 1}`,
		`${count}`,
		NAME + "c",
		`${new Shower().box()}`,
		`${cell()}`,
		`${ITEMS.length}`,
		`${CFG.a + 1}`,
		`${inc(41)}`,
	];
	return parts.join(" ");
}

let block = false;
block = true;
const LATER = 41;
let count = 41;
const NAME = "ab";
let BOX = makeBox();
const CELL = new Cell();
let ITEMS = [1, 2, 3];
const CFG = { a: 41 };
const inc = (x: int32): int32 => x + 1;

bump();
console.log(report());
