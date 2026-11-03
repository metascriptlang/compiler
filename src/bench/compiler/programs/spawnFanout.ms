import { argv } from "std/process";

async function fan(n: int32): Promise<int64> {
	const tasks: Promise<int32>[] = [];
	for (let i: int32 = 0; i < n; i++) { const k = i; tasks.push(spawn((): int32 => k * 2)); }
	let total: int64 = 0;
	for (const t of tasks) total += await t;
	return total;
}

async function words(n: int32): Promise<int64> {
	const tasks: Promise<string>[] = [];
	for (let i: int32 = 0; i < n; i++) { const k = i; tasks.push(spawn((): string => "w" + k.toString())); }
	let total: int64 = 0;
	for (const t of tasks) total += (await t).length;
	return total;
}

async function nested(n: int32): Promise<int64> {
	const tasks: Promise<int32>[] = [];
	for (let i: int32 = 0; i < n; i++) {
		const k = i;
		tasks.push(spawn((): int32 => {
			const inner = spawn((): int32 => k + 1);
			return await inner;
		}));
	}
	let total: int64 = 0;
	for (const t of tasks) total += await t;
	return total;
}

async function once(kind: string, n: int32): Promise<int64> {
	if (kind == "fan") return await fan(n);
	if (kind == "words") return await words(n);
	if (kind == "nested") return await nested(n);
	throw new Error(`unknown case ${kind}`);
}

async function run(kind: string, n: int32, reps: int32): Promise<int64> {
	let total: int64 = 0;
	for (let r: int32 = 0; r < reps; r++) total += await once(kind, n);
	return total;
}

async function main(): Promise<void> {
	if (argv.length > 3) {
		const total = await run(argv[1], argv[2].parseInt() as int32, argv[3].parseInt() as int32);
		console.log(`${argv[1]} ${argv[2]} ${total}`);
		return;
	}
	const kinds = ["fan", "words", "nested"];
	const sizes: int32[] = [10, 1000, 100000];
	let total: int64 = 0;
	for (const kind of kinds) {
		for (const size of sizes) {
			const reps: int32 = size == 100000 ? 1 : 100000 / size;
			total += await run(kind, size, reps);
		}
	}
	console.log(`spawnFanout ${total}`);
}

await main();
