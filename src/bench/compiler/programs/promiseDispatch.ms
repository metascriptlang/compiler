import { argv } from "std/process";

let fired: int32 = 0;
let sum: int64 = 0;

async function leaf(i: int32): Promise<int32> { return i; }

async function chain(depth: int32): Promise<int32> {
	if (depth == 0) return 1;
	return (await chain(depth - 1)) + 1;
}

function afterTimers(target: int32, ms: int32): Promise<void> {
	return new Promise<void>((resolve) => {
		for (let i: int32 = 0; i < target; i++) {
			setTimeout(() => {
				fired += 1;
				if (fired == target) resolve();
			}, ms);
		}
	});
}

async function once(kind: string, n: int32): Promise<int64> {
	if (kind == "await1") {
		let total: int64 = 0;
		for (let i: int32 = 0; i < n; i++) total += await leaf(i);
		return total;
	}
	if (kind == "chain100" || kind == "chain3000") {
		const depth: int32 = kind == "chain100" ? 100 : 3000;
		let total: int64 = 0;
		for (let i: int32 = 0; i < n; i++) total += await chain(depth);
		return total;
	}
	if (kind == "micro") {
		sum = 0;
		let p: Promise<int32> = Promise.resolve(0 as int32);
		for (let i: int32 = 0; i < n; i++) p = p.then((v: int32): int32 => { sum += 1; return v; });
		await p;
		return sum;
	}
	if (kind == "timeout0" || kind == "timerEqual") {
		fired = 0;
		await afterTimers(n, kind == "timeout0" ? 0 : 1);
		return fired;
	}
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
	const kinds = ["await1", "chain100", "chain3000", "micro", "timeout0", "timerEqual"];
	const sizes: int32[] = [100000, 1000, 30, 100000, 100000, 100000];
	const repss: int32[] = [50, 20, 20, 15, 20, 20];
	let total: int64 = 0;
	for (let k = 0; k < kinds.length; k++) total += await run(kinds[k], sizes[k], repss[k]);
	console.log(`promiseDispatch ${total}`);
}

await main();
