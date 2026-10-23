// @stdout: queued ok=true
// @stdout: deep ok=true
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so no wait blocks a worker
// note: more tasks than workers each await a promise that the main thread resolves once that task's child has run, through a callback; the promise has no edge to that child, so once every worker waits the children sit queued behind them. Such a wait starts a spare thread for the queue (counted under the 64-thread limit, retired when the wait ends). `queued` waits directly, `deep` at the bottom of a chain of 32 nested handle waits. The tasks borrow their promise, so each level spawns, recurses, then awaits its own task in its own scope.
import { cpuCount } from "std/os";

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

const n = cpuCount() + 2;
console.log(`queued ok=${fan(0, n, 0) == 5 * n}`);
console.log(`deep ok=${fan(0, n, 32) == 5 * n}`);
