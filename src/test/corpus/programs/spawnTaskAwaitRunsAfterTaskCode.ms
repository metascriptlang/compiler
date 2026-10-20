// @xfail(c): the continuation of an async call made in a spawn task runs on the loop thread, concurrently with the task, so the count loses updates (PARALOCK-runtime Amendment R)
// @xfail(danger): the continuation of an async call made in a spawn task runs on the loop thread, concurrently with the task, so the count loses updates (PARALOCK-runtime Amendment R)
// @xfail(raiser): raiser runtime error: interpretation requires too many iterations (limit 10000000)
// @serial

import { sleepAsync } from "std/core/promise";

class Box { n: int64 = 0; }

async function bump(b: Box): Promise<void> {
	await sleepAsync(0);
	for (let i = 0; i < 3000000; i++) b.n++;
}

async function run(syncLoop: int32): Promise<void> {
	const hs: Promise<int64>[] = [];
	for (let j = 0; j < 4; j++) {
		hs.push(spawn(() => {
			const b = new Box();
			const p = bump(b);
			for (let i = 0; i < syncLoop; i++) b.n++;
			await p;
			return b.n;
		}));
	}
	for (const h of hs) {
		console.log(`loop ${syncLoop} n ${await h}`);
	}
}

async function main(): Promise<void> {
	await run(3000000);
	await run(30000000);
}

main();
