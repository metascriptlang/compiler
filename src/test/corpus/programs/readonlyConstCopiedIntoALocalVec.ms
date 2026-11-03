// @stdout: 2
// @stdout: 2
// @stdout: 1
// note: a Sendable function and a spawn read a Readonly module const and copy its elements into a fresh local Vec; push writes only that local, so the const crosses and nothing is charged as module state.

struct Slice { offset: int32; }
struct Shape { slices: Vec<Slice>; }

const shape: Readonly<Shape> = { slices: [{ offset: 1 }, { offset: 2 }] };

function copies(slices: Readonly<Vec<Slice>>): Vec<Slice> {
	let out: Vec<Slice> = [];
	for (const slice of slices) { out.push({ offset: slice.offset }); }
	return out;
}

function count(): int32 {
	return copies(shape.slices).length;
}

function firstOffset(this s: Readonly<Shape>): int32 {
	let out: Vec<int32> = [];
	out.push(s.slices[0].offset);
	return out[0];
}

const run: Sendable<() => int32> = (): int32 => count();
console.log(`${run()}`);
const f = spawn(() => count());
console.log(`${await f}`);
const g = spawn(() => shape.firstOffset());
console.log(`${await g}`);
