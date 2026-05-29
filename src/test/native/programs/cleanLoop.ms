// Real program — must stay flat (the always-green control).
// 3M iterations of heap-allocating interface construction with a string field.
// Every allocation has a clear owner and is dropped each iteration; steady-state
// RSS must not grow. Accumulator is kept bounded (% ...) so signed-overflow
// UBSan traps can never mask a real result — a crash here means RC, not UB.

interface Row { key: string; tag: number; }

function makeRow(i: number): Row {
	return { key: `row-${i % 1000}-payload-padding-bytes`, tag: i % 7 };
}

function main(): void {
	let acc = 0;
	let i = 0;
	while (i < 3000000) {
		const r = makeRow(i);
		acc = (acc + r.tag + (r.key.length % 13)) % 1000000;
		i = i + 1;
	}
	console.log(`clean-loop acc=${acc}`);
}
