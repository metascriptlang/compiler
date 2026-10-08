// @stdout: 5 5 8 2 9 6 3 12 6
// note: a sized array's dimension is a compile-time integer expression: a const plus or times a literal, two literals, an imported const minus a literal, in a local, a struct field, a parameter type and a struct declared above the const it reads. Same output on every backend.

import { WIDTH } from "./lib/limits";

const COUNT: int32 = 4;

struct Frame {
	bytes: uint8[COUNT + 1],
	wide: int32[WIDTH * 2],
}

struct Early {
	cells: int32[LATE * 2],
}

const LATE: int32 = 3;

function total(xs: int32[COUNT - 1]): int32 {
	let sum = 0;
	for (const x of xs) { sum += x; }
	return sum;
}

function main(): void {
	let plusOne: int32[COUNT + 1] = [];
	let literals: int32[4 + 1] = [];
	let doubled: int32[COUNT * 2] = [];
	let imported: int32[WIDTH - 1] = [];
	let frame: Frame = { bytes: [], wide: [] };
	frame.bytes[COUNT] = 9;
	let three: int32[COUNT - 1] = [];
	three[0] = 1;
	three[2] = 2;
	let early: Early = { cells: [] };
	early.cells[5] = 6;
	const lengths = `${plusOne.length} ${literals.length} ${doubled.length} ${imported.length}`;
	console.log(`${lengths} ${frame.bytes[4]} ${frame.wide.length} ${total(three)} ${frame.bytes.length + doubled.length - 1} ${early.cells[5]}`);
}
main();
