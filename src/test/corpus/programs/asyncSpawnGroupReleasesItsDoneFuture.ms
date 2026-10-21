// @serial
// @stdout: boxes 3000
// @stdout: outer 6000
// @stdout: arrow 3000
// @stdout: top 3000
// note: inside an async function, `await Promise.all([spawn(..), ..])` waits on a done
//   future the lowering creates; its temp was typed as a raw pointer, so nothing released
//   the temp's own reference and every await leaked one future (SAN ledger msFuture
//   alloc 4003, destroy 1003 before the fix). Rounds vary the payload (class, int32,
//   string), the slot count, nesting (an async function awaited by another), an async
//   arrow, and the top-level blocking path as a control.

class Box { v: int32; constructor(v: int32) { this.v = v; } }

function mkBox(v: int32): Box { return new Box(v); }

async function boxes(): Promise<int32> {
	let total: int32 = 0;
	for (let i = 0; i < 1000; i += 1) {
		const bs = await Promise.all([spawn(() => mkBox(1)), spawn(() => mkBox(2))]);
		total += bs[0].v + bs[1].v;
	}
	return total;
}

async function inner(k: int32): Promise<int32> {
	const xs = await Promise.all([spawn((): int32 => k), spawn((): int32 => k + 1), spawn((): int32 => k + 2)]);
	return xs[0] + xs[1] + xs[2];
}

async function outer(): Promise<int32> {
	let total: int32 = 0;
	for (let i = 0; i < 1000; i += 1) {
		total += await inner(1);
	}
	return total;
}

const viaArrow = async (): Promise<int32> => {
	let total: int32 = 0;
	for (let i = 0; i < 1000; i += 1) {
		const ss = await Promise.all([spawn(() => "a"), spawn(() => "bc")]);
		total += ss[0].length + ss[1].length;
	}
	return total;
};

let top: int32 = 0;
for (let i = 0; i < 1000; i += 1) {
	const ys = await Promise.all([spawn((): int32 => 1), spawn((): int32 => 2)]);
	top += ys[0] + ys[1];
}

console.log(`boxes ${await boxes()}`);
console.log(`outer ${await outer()}`);
console.log(`arrow ${await viaArrow()}`);
console.log(`top ${top}`);
