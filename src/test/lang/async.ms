// Language tests: async/await patterns
// NOTE: async in MetaScript compiles to state-machine coroutines (C) or native async (JS).
// Full async execution requires runtime event loop; here we test compilation + sync helpers.

interface Point {
	x: number;
	y: number;
}

type SqrtResult = Result<number, string>;

async function asyncAdd(a: number, b: number): number {
	return a + b;
}

async function asyncDouble(x: number): number {
	return x * 2;
}

async function asyncChain(x: number): number {
	const doubled = await asyncDouble(x);
	const added = await asyncAdd(doubled, 10);
	return added;
}

async function asyncMax(a: number, b: number): number {
	if (a > b) return a;
	return b;
}

async function asyncSum(arr: number[]): number {
	let total = 0;
	let i = 0;
	while (i < arr.length) {
		total += arr[i];
		i += 1;
	}
	return total;
}

async function asyncFind(arr: number[], target: number): number {
	let i = 0;
	while (i < arr.length) {
		if (arr[i] === target) return i;
		i += 1;
	}
	return -1;
}

// Exercises break/continue inside async loop. Pre-bug031 fix the generator
// state-machine emitted bare C `break;`/`continue;` which exited the outer
// dispatcher while(1) without completing the return future → deadlock.
// for..of is lowered to while BEFORE generatorLower so this hits the same fix path.
async function asyncTakeUntil(arr: number[], stopAt: number): number {
	let sum = 0;
	for (const v of arr) {
		if (v === stopAt) break;
		sum += v;
	}
	return sum;
}

async function asyncSumSkipping(arr: number[], skip: number): number {
	let total = 0;
	for (const v of arr) {
		if (v === skip) continue;
		total += v;
	}
	return total;
}

async function asyncDistance(a: Point, b: Point): number {
	const dx = a.x - b.x;
	const dy = a.y - b.y;
	return dx * dx + dy * dy;
}

function safeSqrt(x: number): SqrtResult {
	if (x < 0) return Result.err("negative");
	let r = 0;
	while (r * r <= x) { r += 1; }
	return Result.ok(r - 1);
}

async function asyncPipeline(x: number): SqrtResult {
	const root = try safeSqrt(x);
	const doubled = await asyncDouble(root);
	return Result.ok(doubled);
}

test "safeSqrt helper" {
	const r1 = safeSqrt(9);
	assert r1.ok;
	assert r1.value === 3;

	const r2 = safeSqrt(0);
	assert r2.ok;
	assert r2.value === 0;

	const r3 = safeSqrt(-1);
	assert !r3.ok;
	assert r3.error === "negative";

	const r4 = safeSqrt(16);
	assert r4.ok;
	assert r4.value === 4;

	const r5 = safeSqrt(25);
	assert r5.ok;
	assert r5.value === 5;
}
