// @stdout: worker-exit sibling armed 45
// @exit: 3
// @serial
// @skip-js: Locked<T> is a C-only synchronization cell; JavaScript has no pool workers
// @skip-raiser

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Ready { n: int32; }

function spin(n: int32): int32 {
	let sum: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) sum = (sum + i) % 1000;
	return sum;
}

function busy(ready: Locked<Ready>): void {
	lockedUpdate(ready, (v: Ready): Ready => { return { n: 1 }; });
	while (lockedRead(ready, (v: Ready): int32 => { return v.n; }) == 1) { }
}

function quit(): int32 {
	process.exit(3);
	return 0;
}

console.log(`worker-exit sibling armed ${await spawn(() => spin(10))}`);
const ready: Locked<Ready> = new Locked({ n: 0 });
const active = spawn(() => busy(ready));
while (lockedRead(ready, (v: Ready): int32 => { return v.n; }) == 0) { }
const killer = spawn(() => quit());
const local = spin(5000000);
console.log(`SHOULD-NOT-REACH ${await killer + local}`);
await active;
