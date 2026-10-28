// @stdout: call 1 sends 4 main 1
// @serial
// note: the first actor of the program is created on a pool worker; scheduler 0 stays the
//   event-loop thread, so calls from main still run once every worker has gone idle.
actor Counter {
	n: int32 = 0;
	bump(): void {
		this.n = this.n + 1;
	}
	next(): int32 {
		this.n = this.n + 1;
		return this.n;
	}
}

async function run(): Promise<void> {
	const c = await spawn(() => new Counter());
	await sleepAsync(50);
	const call = await c.next();
	c.bump();
	c.bump();
	await sleepAsync(50);
	const sends = await c.next();
	const m = new Counter();
	await sleepAsync(50);
	const main = await m.next();
	console.log(`call ${call} sends ${sends} main ${main}`);
}
run();
