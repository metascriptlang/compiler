// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @maxrss: 40
// @stdout: sends 100000 ints 100000 strs 100000 pts 100000
// @serial
// note: the bound sits between a dispatch whose future the resume releases (22 MB, macOS)
//   and one that never releases it (59 MB): 112 B per suspending SEND or CALL.
struct Pt {
	x: int32;
	y: int32;
}

actor Sink {
	n: int32;
	constructor() {
		this.n = 0;
	}
	work(): void {
		const r = await spawn(() => 1);
		this.n = this.n + r;
	}
	count(): int32 {
		return this.n;
	}
	num(): int32 {
		const r = await spawn(() => 1);
		return r;
	}
	tag(): string {
		const r = await spawn(() => 2);
		return "t" + r.toString();
	}
	pt(): Pt {
		const r = await spawn(() => 3);
		return { x: r, y: r + 1 };
	}
}

async function main(): Promise<void> {
	const s = new Sink();
	for (let i = 0; i < 100000; i = i + 1) {
		s.work();
	}
	const sends = await s.count();
	let ints = 0;
	let strs = 0;
	let pts = 0;
	for (let i = 0; i < 100000; i = i + 1) {
		const a = s.num();
		const b = s.tag();
		const c = s.pt();
		ints = ints + (await a);
		if ((await b) == "t2") {
			strs = strs + 1;
		}
		const p = await c;
		if (p.x == 3 && p.y == 4) {
			pts = pts + 1;
		}
	}
	console.log("sends " + sends.toString() + " ints " + ints.toString() + " strs " + strs.toString() + " pts " + pts.toString());
}
main();
