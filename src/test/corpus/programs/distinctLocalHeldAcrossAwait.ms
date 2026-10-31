// Parity program — a local of a distinct scalar type lives in the async frame across an await and
// starts as the base type's zero.
// Axes: distinct int64, uint32, float64; held across one await, across two awaits in a loop,
// captured by a closure that runs after an await, and held inside a nested async arrow.
//
// @stdout: handled 7
// @stdout: 5 4000000000 2.5
// @stdout: 11 11
// @stdout: 9
// @exit: 0

import { sleepAsync } from "std/core/promise";

type RequestId = distinct int64;
type Port = distinct uint32;
type Ratio = distinct float64;

interface Frame { requestId: RequestId; }

async function handle(frame: Frame): Promise<void> {
	const requestId = frame.requestId;
	await sleepAsync(1);
	console.log("handled", requestId as int64);
}

async function scalars(): Promise<void> {
	const id = 5 as RequestId;
	const port = 4000000000 as Port;
	const ratio = 2.5 as Ratio;
	await sleepAsync(1);
	console.log(`${id as int64} ${port as uint32} ${ratio as float64}`);
}

async function loop(): Promise<int64> {
	let total: int64 = 0;
	for (let i = 1; i <= 3; i += 1) {
		const step = (i as int64) as RequestId;
		await sleepAsync(1);
		const doubled = (step as int64) * 2;
		await sleepAsync(1);
		total += doubled;
	}
	return total - 1;
}

async function captured(): Promise<int64> {
	const base = 4 as RequestId;
	const add = (n: int64): int64 => (base as int64) + n;
	await sleepAsync(1);
	return add(7);
}

async function nested(): Promise<int64> {
	const inner = async (): Promise<int64> => {
		const v = 9 as RequestId;
		await sleepAsync(1);
		return v as int64;
	};
	return await inner();
}

await handle({ requestId: 7 as RequestId });
await scalars();
console.log(`${await loop()} ${await captured()}`);
console.log(await nested());
