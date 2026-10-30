import { argv } from "std/process";

type Resolver = (value: int32) => void;

async function row(n: int32): Promise<int32[]> { return [n, n]; }

function inputs(n: int32, pending: boolean, resolvers: Resolver[]): Promise<int32>[] {
	const ps: Promise<int32>[] = [];
	for (let i: int32 = 0; i < n; i++) {
		if (pending) {
			ps.push(new Promise<int32>((resolve) => { resolvers.push(resolve); }));
		} else {
			ps.push(Promise.resolve(i));
		}
	}
	return ps;
}

function wordInputs(n: int32, pending: boolean, resolvers: Resolver[]): Promise<string>[] {
	const ps: Promise<string>[] = [];
	for (let i: int32 = 0; i < n; i++) {
		if (pending) {
			ps.push(new Promise<string>((resolve) => { resolvers.push((v: int32): void => { resolve("w"); }); }));
		} else {
			ps.push(Promise.resolve("w"));
		}
	}
	return ps;
}

function settleAll(resolvers: Resolver[]): void {
	for (let i = 0; i < resolvers.length; i++) resolvers[i](i as int32);
}

async function once(kind: string, pending: boolean, n: int32): Promise<int64> {
	const resolvers: Resolver[] = [];
	let sum: int64 = 0;
	if (kind == "allArr") {
		const ps: Promise<int32[]>[] = [];
		for (let i: int32 = 0; i < n; i++) ps.push(row(i));
		return (await Promise.all(ps)).length;
	}
	if (kind == "allStr") {
		const p = Promise.all(wordInputs(n, pending, resolvers));
		settleAll(resolvers);
		return (await p).length;
	}
	const ps = inputs(n, pending, resolvers);
	if (kind == "all") {
		const p = Promise.all(ps);
		settleAll(resolvers);
		sum += (await p).length;
	} else if (kind == "allSettled") {
		const p = Promise.allSettled(ps);
		settleAll(resolvers);
		await p;
		sum += n;
	} else if (kind == "race") {
		const p = Promise.race(ps);
		settleAll(resolvers);
		sum += await p;
	} else if (kind == "any") {
		const p = Promise.any(ps);
		settleAll(resolvers);
		sum += await p;
	}
	return sum;
}

async function run(kind: string, pending: boolean, n: int32, reps: int32): Promise<int64> {
	let sum: int64 = 0;
	for (let r: int32 = 0; r < reps; r++) sum += await once(kind, pending, n);
	return sum;
}

async function main(): Promise<void> {
	if (argv.length > 4) {
		const total = await run(argv[1], argv[2] == "pending", argv[3].parseInt() as int32, argv[4].parseInt() as int32);
		console.log(`${argv[1]} ${argv[2]} ${argv[3]} ${total}`);
		return;
	}
	const kinds = ["all", "allArr", "allStr", "allSettled", "race", "any"];
	const sizes: int32[] = [10, 1000, 100000];
	let total: int64 = 0;
	for (const kind of kinds) {
		for (const size of sizes) {
			const reps: int32 = size == 100000 ? 2 : 20000 / size;
			total += await run(kind, false, size, reps);
			total += await run(kind, true, size, reps);
		}
	}
	console.log(`promiseCombinators ${total}`);
}

await main();
