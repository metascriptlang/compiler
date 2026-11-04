// Every row walks 65536 int32 values once per call; array rows then bump one element and generator rows take a new
// salt, so no call can be hoisted out of the timing loop. Sums stay int32: an int64 is a BigInt on the node arm.

import { bench } from "../harness";

const SIZE: int32 = 65536;
const SIDE: int32 = 256;

let sink: number = 0;
let pass: int32 = 0;

function nextPass(): int32 {
	pass++;
	return pass;
}

function filled(count: int32, step: int32, offset: int32): int32[] {
	const out: int32[] = [];
	for (let i: int32 = 0; i < count; i++) out.push((i * step + offset) % 1000);
	return out;
}

function bump(values: int32[]): void {
	const at = nextPass() % values.length;
	values[at] = values[at] + 1;
}

const arr = filled(SIZE, 7, 3);
const other = filled(SIZE, 13, 5);
let vec: Vec<int32> = [];
for (const x of arr) vec.push(x);
const grid: int32[][] = [];
for (let r: int32 = 0; r < SIDE; r++) grid.push(filled(SIDE, 7, r));

function indexedSum(values: int32[]): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < values.length; i++) total += values[i];
	return total;
}

function forOfSum(values: int32[]): int32 {
	let total: int32 = 0;
	for (const x of values) total += x;
	return total;
}

function vecSum(values: Vec<int32>): int32 {
	let total: int32 = 0;
	for (const x of values) total += x;
	return total;
}

function valuesSum(values: int32[]): int32 {
	let total: int32 = 0;
	for (const x of values.values()) total += x;
	return total;
}

function keysSum(values: int32[]): int32 {
	let total: int32 = 0;
	for (const i of values.keys()) total += values[i];
	return total;
}

function entriesSum(values: int32[]): int32 {
	let total: int32 = 0;
	for (const [i, x] of values.entries()) total += x + ((i as int32) & 1);
	return total;
}

function gridSum(rows: int32[][]): int32 {
	let total: int32 = 0;
	for (const row of rows) {
		for (const x of row) total += x;
	}
	return total;
}

function* upTo(limit: int32): Iterator<int32> {
	for (let i: int32 = 0; i < limit; i++) yield i;
}

function* relay(limit: int32): Iterator<int32> {
	for (const x of upTo(limit)) yield x;
}

function generatorSum(salt: int32): int32 {
	let total: int32 = 0;
	for (const x of upTo(SIZE)) total += (x ^ salt) & 1023;
	return total;
}

function nestedGeneratorSum(salt: int32): int32 {
	let total: int32 = 0;
	for (const x of relay(SIZE)) total += (x ^ salt) & 1023;
	return total;
}

function rangeSum(salt: int32): number {
	let total: number = 0;
	for (const x of Iterator.range(salt, salt + SIZE)) total += x;
	return total;
}

function chainForOfSum(values: int32[]): int32 {
	const chain = values
		.values()
		.map((x) => x * 2)
		.filter((x) => x % 3 != 0)
		.take(SIZE / 2);
	let total: int32 = 0;
	for (const x of chain) total += x;
	return total;
}

function chainReduceSum(values: int32[]): int32 {
	return values
		.values()
		.map((x) => x * 2)
		.filter((x) => x % 3 != 0)
		.take(SIZE / 2)
		.reduce((acc: int32, x) => acc + x, 0 as int32);
}

function makeChain(values: int32[]): Iterator<int32> {
	return values
		.values()
		.map((x) => x * 2)
		.filter((x) => x % 3 != 0)
		.take(SIZE / 2);
}

function storedChainSum(values: int32[]): int32 {
	let total: int32 = 0;
	for (const x of makeChain(values)) total += x;
	return total;
}

function toArraySum(values: int32[]): int32 {
	const out = values
		.values()
		.map((x) => x * 2)
		.toArray();
	let total: int32 = 0;
	for (const x of out) total += x;
	return total;
}

function zipSum(left: int32[], right: int32[]): int32 {
	let total: int32 = 0;
	for (const pair of Iterator.zip([left.values(), right.values()])) {
		total += (pair[0] * pair[1]) & 1023;
	}
	return total;
}

function eagerSum(values: int32[]): int32 {
	return values
		.map((x) => x * 2)
		.filter((x) => x % 3 != 0)
		.reduce((acc: int32, x) => acc + x, 0 as int32);
}

bench("indexed for int32[]", 0, () => { sink += indexedSum(arr); bump(arr); });
bench("for-of int32[]", 0, () => { sink += forOfSum(arr); bump(arr); });
bench("for-of Vec<int32>", 0, () => {
	sink += vecSum(vec);
	const at = nextPass() % SIZE;
	vec[at] = vec[at] + 1;
});
bench("for-of values()", 0, () => { sink += valuesSum(arr); bump(arr); });
bench("for-of keys()", 0, () => { sink += keysSum(arr); bump(arr); });
bench("for-of entries()", 0, () => { sink += entriesSum(arr); bump(arr); });
bench("for-of nested 256x256", 0, () => {
	sink += gridSum(grid);
	bump(grid[nextPass() % SIDE]);
});
bench("generator", 0, () => { sink += generatorSum(nextPass()); });
bench("nested generator", 0, () => {
	sink += nestedGeneratorSum(nextPass());
});
bench("Iterator.range float64", 0, () => { sink += rangeSum(nextPass()); });
bench("chain for-of", 0, () => { sink += chainForOfSum(arr); bump(arr); });
bench("chain reduce", 0, () => { sink += chainReduceSum(arr); bump(arr); });
bench("chain stored in a function", 0, () => {
	sink += storedChainSum(arr);
	bump(arr);
});
bench("map toArray", 0, () => { sink += toArraySum(arr); bump(arr); });
bench("zip product", 0, () => { sink += zipSum(arr, other); bump(arr); });
bench("eager map filter reduce", 0, () => { sink += eagerSum(arr); bump(arr); });

if (sink < 0) console.log("unreachable", sink);
