// @stdout: then 2
// @stdout: caught boom
// @stdout: finally
// @stdout: pass 5
// @stdout: finally-after-reject
// @stdout: caught again
// note: then, catch and finally each complete their output future: then maps a value, catch passes a success through and handles a failure, finally runs its callback and passes the original outcome through.

async function main(): Promise<void> {
	const a: int32 = await Promise.resolve(1).then((v: int32): int32 => v + 1);
	console.log(`then ${a}`);
	const failing: Promise<int32> = Promise.reject(new Error("boom"));
	const b: int32 = await failing.catch((e: Error): int32 => { console.log(`caught ${e.message}`); return 0; });
	const ok: Promise<int32> = Promise.resolve(5);
	const c: int32 = await ok.catch((e: Error): int32 => 0).finally((): void => { console.log("finally"); });
	console.log(`pass ${c + b}`);
	const again: Promise<int32> = Promise.reject(new Error("again"));
	await again.finally((): void => { console.log("finally-after-reject"); }).catch((e: Error): int32 => { console.log(`caught ${e.message}`); return 0; });
}
await main();
