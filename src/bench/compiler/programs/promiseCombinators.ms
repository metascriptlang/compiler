import { argv } from "std/process";

type Resolver = (value: int32) => void;

let seen: int64 = 0;

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
	if (kind == "thenStr") {
		const outs: Promise<void>[] = [];
		for (const p of wordInputs(n, pending, resolvers)) outs.push(p.then((v: string): void => { seen += v.length; }));
		settleAll(resolvers);
		for (const o of outs) await o;
		return seen;
	}
	const ps = inputs(n, pending, resolvers);
	if (kind == "then") {
		const outs: Promise<void>[] = [];
		for (const p of ps) outs.push(p.then((v: int32): void => { seen += v; }));
		settleAll(resolvers);
		for (const o of outs) await o;
		return seen;
	}
	if (kind == "catch") {
		const outs: Promise<int32>[] = [];
		for (const p of ps) outs.push(p.catch((e: Error): int32 => -1));
		settleAll(resolvers);
		for (const o of outs) sum += await o;
		return sum;
	}
	if (kind == "finally") {
		const outs: Promise<int32>[] = [];
		for (const p of ps) outs.push(p.finally((): void => { seen += 1; }));
		settleAll(resolvers);
		for (const o of outs) sum += await o;
		return sum + seen;
	}
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
	const kinds = ["all", "allArr", "allStr", "allSettled", "race", "any", "then", "thenStr", "catch", "finally"];
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
