// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @maxrss: 22
// @stdout: ints 100000 strs 100000
// @serial
// note: the bound sits between a reply that drains (13 MB, macOS) and one that
//   completes on the worker and never releases the reply's in-flight ref (31 MB).

actor Pump {
	n: int32;
	constructor() {
		this.n = 0;
	}
	work(): int32 {
		const r = await spawn(() => 1);
		this.n = this.n + r;
		return r;
	}
	tag(): string {
		const r = await spawn(() => 2);
		this.n = this.n + r;
		return "t" + r.toString();
	}
}

async function main(): Promise<void> {
	const a = new Pump();
	const b = new Pump();
	let ints = 0;
	let strs = 0;
	for (let i = 0; i < 100000; i = i + 1) {
		const x = a.work();
		const y = b.tag();
		ints = ints + (await x);
		if ((await y) == "t2") {
			strs = strs + 1;
		}
	}
	console.log("ints " + ints.toString() + " strs " + strs.toString());
}
main();
