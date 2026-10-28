// @stdout: closure 4
// @stdout: captured 9
// @stdout: array 3
// note: the value a spawned task returns moves into its future: the task keeps no count on it, whether it is a closure without an environment, a closure that captures, or an array.
function reader(n: int32): Sendable<() => int32> {
	return (): int32 => n;
}

function rows(n: int32): int32[] {
	const out: int32[] = [];
	for (let i = 0; i < n; i += 1) out.push(i);
	return out;
}

async function run(): Promise<void> {
	const read = await spawn(() => reader(4));
	console.log(`closure ${read()}`);
	const kept = await spawn((): Sendable<() => int32> => { const r = reader(9); return r; });
	console.log(`captured ${kept()}`);
	const got = await spawn(() => rows(3));
	console.log(`array ${got.length}`);
}

await run();
