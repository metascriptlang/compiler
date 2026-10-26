// @selftest-red none
// @stdout: actor-reply 20100
actor Counter {
	n: int32;
	constructor() { this.n = 0; }
	add(k: int32): int32 {
		this.n = this.n + k;
		return this.n;
	}
}

async function main(): Promise<void> {
	const c = new Counter();
	let last: int32 = 0;
	for (let i = 1; i <= 200; i++) last = await c.add(i);
	console.log(`actor-reply ${last}`);
}
main();
