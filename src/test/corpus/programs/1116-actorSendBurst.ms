// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: one 6000000
// @stdout: two 6000000 6000000
// @stdout: three 200000 200000 200000

actor Counter {
	n: int32;
	constructor() {
		this.n = 0;
	}
	add(k: int32): void {
		this.n = this.n + k;
	}
	get(): int32 {
		return this.n;
	}
}

async function main(): Promise<void> {
	const c = new Counter();
	let one = 0;
	for (let r = 0; r < 60; r = r + 1) {
		for (let i = 0; i < 100000; i = i + 1) {
			c.add(1);
		}
		one = await c.get();
	}
	console.log("one " + one.toString());

	const a = new Counter();
	const b = new Counter();
	let x = 0;
	let y = 0;
	for (let r = 0; r < 60; r = r + 1) {
		for (let i = 0; i < 100000; i = i + 1) {
			a.add(1);
			b.add(1);
		}
		x = await a.get();
		y = await b.get();
	}
	console.log("two " + x.toString() + " " + y.toString());

	const p = new Counter();
	const q = new Counter();
	const s = new Counter();
	for (let i = 0; i < 200000; i = i + 1) {
		p.add(1);
		q.add(1);
		s.add(1);
	}
	const pn = await p.get();
	const qn = await q.get();
	const sn = await s.get();
	console.log("three " + pn.toString() + " " + qn.toString() + " " + sn.toString());
}
main();
