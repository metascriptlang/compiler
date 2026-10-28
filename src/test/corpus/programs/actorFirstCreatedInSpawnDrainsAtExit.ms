// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: logged 3
// @serial
// note: the first actor of the program is created on a pool worker and only receives sends;
//   the exit drain still runs them after every worker has gone idle.
actor Logger {
	n: int32 = 0;
	log(): void {
		this.n = this.n + 1;
		if (this.n == 3) console.log(`logged ${this.n}`);
	}
}

async function run(): Promise<void> {
	const l = await spawn(() => new Logger());
	await sleepAsync(50);
	l.log();
	l.log();
	l.log();
}
run();
