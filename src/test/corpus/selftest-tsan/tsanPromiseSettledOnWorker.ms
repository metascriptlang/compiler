// @selftest-red none
// @stdout: promise-on-worker 400
actor Waiter {
	n: int32;
	constructor() { this.n = 0; }
	work(): void {
		const r = await spawn(() => 2);
		this.n = this.n + r;
	}
	total(): int32 { return this.n; }
}

async function main(): Promise<void> {
	const w = new Waiter();
	for (let i = 0; i < 200; i++) w.work();
	const t = await w.total();
	console.log(`promise-on-worker ${t}`);
}
main();
