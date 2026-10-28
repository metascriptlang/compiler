// @stdout: workers=96 queued ok=true
// @stdout: deep ok=true
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so no wait blocks a worker
// note: spawnResolverLeafUnderDeepChain on a pool sized as a 96-CPU host sizes it, whatever this host has: more tasks than workers each await a promise the main thread resolves once that task's child has run, so every worker waits and the children run on spare threads. The spares need room beyond the workers under the pool-thread limit; when the limit counted the workers, a host of 64 or more CPUs had none and the wait stopped the process.
extern function msPoolSetWorkerCount(count: int32): boolean;

let resolvers: ((v: int32) => void)[] = [];

function chain(d: int32, gate: Promise<int32>): int32 {
	if (d == 0) return await gate;
	const h = spawn(() => chain(d - 1, gate));
	return await h;
}

function fan(i: int32, n: int32, depth: int32): int32 {
	if (i == n) {
		for (const res of resolvers) spawn(() => 5 as int32).then((v: int32): void => res(v));
		resolvers = [];
		return 0;
	}
	const gate = new Promise<int32>((res) => { resolvers.push(res); });
	const h = spawn(() => chain(depth, gate));
	const rest = fan(i + 1, n, depth);
	return rest + await h;
}

const workers: int32 = 96;
const sized = msPoolSetWorkerCount(workers);
const n = workers + 2;
console.log(`workers=${sized ? workers : 0} queued ok=${fan(0, n, 0) == 5 * n}`);
console.log(`deep ok=${fan(0, n, 32) == 5 * n}`);
