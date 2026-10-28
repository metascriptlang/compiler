// @stdout: timer 5
// @stdout: interval 3
// @stdout: task 7
// @stdout: all 6
// @xfail(raiser): raiser runtime error: Unknown host function: msSetTimeout
// note: every source that can still settle an awaited promise keeps the program alive: a timer resolving a promise, an interval, a task that sleeps on its worker, and Promise.all over such tasks. None of them may end it with the unsettled-await exit 13.

const v = await new Promise<int32>((resolve) => { setTimeout(() => { resolve(5); }, 120); });
console.log(`timer ${v}`);

let n = 0;
let h: number = 0;
await new Promise<void>((resolve) => { h = setInterval(() => { n = n + 1; if (n == 3) { clearInterval(h); resolve(); } }, 40); });
console.log(`interval ${n}`);

const t = await spawn((): int32 => { await sleepAsync(120); return 7; });
console.log(`task ${t}`);

const ps: Promise<int32>[] = [];
for (let i = 0; i < 6; i++) { const d = 20 + i * 15; ps.push(spawn((): int32 => { await sleepAsync(d); return 1; })); }
let sum = 0;
for (const r of await Promise.all(ps)) sum = sum + r;
console.log(`all ${sum}`);
