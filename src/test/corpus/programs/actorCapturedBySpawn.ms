// @stdout: send 3 call 3
// @serial
actor Counter {
	n: int32 = 0;
	add(x: int32): void {
		this.n = this.n + x;
	}
	get(): int32 {
		return this.n;
	}
}

async function main(): Promise<void> {
	const c = new Counter();
	const one = spawn(() => { c.add(1); return 1; });
	const two = spawn(() => { c.add(2); return 2; });
	await one;
	await two;
	const read = spawn(() => await c.get());
	const fromTask = await read;
	console.log(`send ${await c.get()} call ${fromTask}`);
}

await main();
