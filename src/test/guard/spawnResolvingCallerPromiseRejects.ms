// A spawned task that calls the resolve function of its caller's promise would run the caller's
// `.then` on the worker, concurrently with the caller's own code, so both would update `total`
// at once. The resolve function is a plain function value, so the spawn is a compile error.
//
// GUARD-CHECK-FAIL spawn runs this thunk on another thread, but it calls a function value

class Box { n: int64 = 0; }

async function main(): Promise<void> {
	const total = new Box();
	let res: ((v: int32) => void) | null = null;
	const p = new Promise<int32>((resolve: (v: int32) => void): void => { res = resolve; });
	const r = res!;
	p.then((v: int32): void => {
		for (let i = 0; i < 1000000; i++) total.n += 1;
	});
	const h = spawn(() => { r(5); return 1; });
	for (let i = 0; i < 3000000; i++) total.n += 1;
	console.log(`spawned ${await h} awaited ${await p} total ${total.n}`);
}

main();
