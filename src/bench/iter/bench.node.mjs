// Node 24 has neither Iterator.range nor Iterator.zip: those two rows use the plain generator equivalents.

import { bench } from "../harness.mjs";

const SIZE = 65536;
const SIDE = 256;

let sink = 0;
let pass = 0;

function nextPass() {
	pass++;
	return pass;
}

function filled(count, step, offset) {
	const out = [];
	for (let i = 0; i < count; i++) out.push((i * step + offset) % 1000);
	return out;
}

function bump(values) {
	const at = nextPass() % values.length;
	values[at] = values[at] + 1;
}

const arr = filled(SIZE, 7, 3);
const other = filled(SIZE, 13, 5);
const vec = Int32Array.from(arr);
const grid = [];
for (let r = 0; r < SIDE; r++) grid.push(filled(SIDE, 7, r));

function indexedSum(values) {
	let total = 0;
	for (let i = 0; i < values.length; i++) total += values[i];
	return total;
}

function forOfSum(values) {
	let total = 0;
	for (const x of values) total += x;
	return total;
}

function valuesSum(values) {
	let total = 0;
	for (const x of values.values()) total += x;
	return total;
}

function keysSum(values) {
	let total = 0;
	for (const i of values.keys()) total += values[i];
	return total;
}

function entriesSum(values) {
	let total = 0;
	for (const [i, x] of values.entries()) total += x + (i & 1);
	return total;
}

function gridSum(rows) {
	let total = 0;
	for (const row of rows) {
		for (const x of row) total += x;
	}
	return total;
}

function* upTo(limit) {
	for (let i = 0; i < limit; i++) yield i;
}

function* relay(limit) {
	for (const x of upTo(limit)) yield x;
}

function* range(start, end) {
	for (let i = start; i < end; i++) yield i;
}

function* zip(iters) {
	while (true) {
		const results = [];
		for (const it of iters) {
			const r = it.next();
			if (r.done) {
				for (const other of iters) other.return?.();
				return;
			}
			results.push(r.value);
		}
		yield results;
	}
}

function generatorSum(salt) {
	let total = 0;
	for (const x of upTo(SIZE)) total += (x ^ salt) & 1023;
	return total;
}

function nestedGeneratorSum(salt) {
	let total = 0;
	for (const x of relay(SIZE)) total += (x ^ salt) & 1023;
	return total;
}

function rangeSum(salt) {
	let total = 0;
	for (const x of range(salt, salt + SIZE)) total += x;
	return total;
}

function chainForOfSum(values) {
	const chain = values
		.values()
		.map((x) => x * 2)
		.filter((x) => x % 3 != 0)
		.take(SIZE / 2);
	let total = 0;
	for (const x of chain) total += x;
	return total;
}

function chainReduceSum(values) {
	return values
		.values()
		.map((x) => x * 2)
		.filter((x) => x % 3 != 0)
		.take(SIZE / 2)
		.reduce((acc, x) => acc + x, 0);
}

function makeChain(values) {
	return values
		.values()
		.map((x) => x * 2)
		.filter((x) => x % 3 != 0)
		.take(SIZE / 2);
}

function storedChainSum(values) {
	let total = 0;
	for (const x of makeChain(values)) total += x;
	return total;
}

function toArraySum(values) {
	const out = values
		.values()
		.map((x) => x * 2)
		.toArray();
	let total = 0;
	for (const x of out) total += x;
	return total;
}

function zipSum(left, right) {
	let total = 0;
	for (const pair of zip([left.values(), right.values()])) total += (pair[0] * pair[1]) & 1023;
	return total;
}

function eagerSum(values) {
	return values
		.map((x) => x * 2)
		.filter((x) => x % 3 != 0)
		.reduce((acc, x) => acc + x, 0);
}

bench("indexed for int32[]", 0, () => { sink += indexedSum(arr); bump(arr); });
bench("for-of int32[]", 0, () => { sink += forOfSum(arr); bump(arr); });
bench("for-of Vec<int32>", 0, () => { sink += forOfSum(vec); bump(vec); });
bench("for-of values()", 0, () => { sink += valuesSum(arr); bump(arr); });
bench("for-of keys()", 0, () => { sink += keysSum(arr); bump(arr); });
bench("for-of entries()", 0, () => { sink += entriesSum(arr); bump(arr); });
bench("for-of nested 256x256", 0, () => { sink += gridSum(grid); bump(grid[nextPass() % SIDE]); });
bench("generator", 0, () => { sink += generatorSum(nextPass()); });
bench("nested generator", 0, () => { sink += nestedGeneratorSum(nextPass()); });
bench("Iterator.range float64", 0, () => { sink += rangeSum(nextPass()); });
bench("chain for-of", 0, () => { sink += chainForOfSum(arr); bump(arr); });
bench("chain reduce", 0, () => { sink += chainReduceSum(arr); bump(arr); });
bench("chain stored in a function", 0, () => { sink += storedChainSum(arr); bump(arr); });
bench("map toArray", 0, () => { sink += toArraySum(arr); bump(arr); });
bench("zip product", 0, () => { sink += zipSum(arr, other); bump(arr); });
bench("eager map filter reduce", 0, () => { sink += eagerSum(arr); bump(arr); });

if (sink < 0) console.log("unreachable", sink);
