// @stdout: queued ok=true
// @stdout: deep ok=true
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so no wait blocks a worker
// note: more tasks than workers each await a promise that only a spawned child settles, through a callback; the promise has no edge to that child, so once every worker waits the children sit queued behind them. Such a wait starts a spare thread for the queue (counted under the 64-thread limit, retired when the wait ends). `queued` waits directly, `deep` at the bottom of a chain of 32 nested handle waits.
import { cpuCount } from "std/os";

function leaf(): int32 {
	const p = new Promise<int32>((res) => {
		spawn(() => 5 as int32).then((v: int32): void => res(v));
	});
	return await p;
}

function chain(d: int32): int32 {
	if (d == 0) return leaf();
	const h = spawn(() => chain(d - 1));
	return await h;
}

const n = cpuCount() + 2;
const direct: Promise<int32>[] = [];
for (let i = 0; i < n; i++) direct.push(spawn(() => leaf()));
let s: int32 = 0;
for (const h of direct) s += await h;
console.log(`queued ok=${s == 5 * n}`);
const deep: Promise<int32>[] = [];
for (let i = 0; i < n; i++) deep.push(spawn(() => chain(32)));
s = 0;
for (const h of deep) s += await h;
console.log(`deep ok=${s == 5 * n}`);
