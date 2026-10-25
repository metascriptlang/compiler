// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: a 2 b 2 main 1
// @serial
// @ledger-slack(Counter) 3
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
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
	const pa = spawn(() => new Counter());
	const pb = spawn(() => new Counter());
	const a = await pa;
	const b = await pb;
	a.bump();
	b.bump();
	await sleepAsync(50);
	const na = await a.next();
	const nb = await b.next();
	const m = new Counter();
	const nm = await m.next();
	console.log(`a ${na} b ${nb} main ${nm}`);
}
run();
