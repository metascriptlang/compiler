// Checked int32 and int16 reductions of generator, keys(), entries() and while-loop terms across many blocks of
// 1024, a subtracting one, and one whose index starts below zero, keep the checked loop's sums.
//
// @stdout: 35684296 -35000 0 -35684296 5000 253110

const SIZE: int32 = 70000;

function* upTo(limit: int32): Iterator<int32> {
	for (let i: int32 = 0; i < limit; i++) yield i;
}

function generatorSum(salt: int32): int32 {
	let total: int32 = 0;
	for (const x of upTo(SIZE)) total += (x ^ salt) & 1023;
	return total;
}

function keysSum(xs: int32[]): int32 {
	let total: int32 = 0;
	for (const k of xs.keys()) total += xs[k];
	return total;
}

function entriesSum(xs: int32[]): int32 {
	let total: int32 = 0;
	for (const [k, x] of xs.entries()) total += x + ((k as int32) & 1);
	return total;
}

function generatorDrain(salt: int32): int32 {
	let total: int32 = 0;
	for (const x of upTo(SIZE)) total -= (x ^ salt) & 1023;
	return total;
}

function narrowSum(): int16 {
	let total: int16 = 0;
	for (let x: int32 = 0; x < 10000; x++) total += ((x & 7) - 3) as int16;
	return total;
}

function fromBelowZero(n: int32): int32 {
	let i: int32 = -3;
	let total: int32 = 0;
	while (i < n) {
		const v: int32 = i * 3;
		total += v & 255;
		i++;
	}
	return total;
}

const xs: int32[] = [];
for (let i: int32 = 0; i < SIZE; i++) xs.push(((i * 7 + 3) % 1000) - 500);
console.log(`${generatorSum(5)} ${keysSum(xs)} ${entriesSum(xs)} ${generatorDrain(5)} ${narrowSum()} ${fromBelowZero(2000)}`);
