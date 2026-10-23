// @stdout: ok=true
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so no wait blocks a worker
// note: more tasks than the 64-thread limit each block their worker in an await of a timer that worker's own loop fires, so each wait settles on its own thread and needs no spare; one spare per wait would reach the limit and stop the program with the thread-limit error.
import { cpuCount } from "std/os";

const n = 64 + cpuCount();
const hs: Promise<int32>[] = [];
for (let i = 0; i < n; i++) hs.push(spawn(() => { await sleepAsync(30); return 1 as int32; }));
let s: int32 = 0;
for (const h of hs) s += await h;
console.log(`ok=${s == n}`);
