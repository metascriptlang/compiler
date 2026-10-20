// @xfail(raiser): the Raiser VM has no actors: Cannot resolve module 'std/actor'
// @stdout: send work 0->0;ping;
// @stdout: call sum=4000000
import { stop, ExitReason } from "std/actor";

actor Frozen {
	n: int32;
	log: string;
	constructor() {
		this.n = 0;
		this.log = "";
	}
	work(): void {
		const before = this.n;
		await spawn(() => 1);
		this.log = this.log + "work " + before.toString() + "->" + this.n.toString() + ";";
	}
	ping(): void {
		this.n = this.n + 1;
		this.log = this.log + "ping;";
	}
	dump(): string {
		return this.log;
	}
}

actor Borrow {
	arr: int32[];
	constructor() {
		this.arr = [];
		for (let i = 0; i < 200000; i = i + 1) {
			this.arr.push(1);
		}
	}
	total(): int32 {
		const r = await spawn(() => {
			let s = 0;
			for (let k = 0; k < 20; k = k + 1) {
				for (let i = 0; i < this.arr.length; i = i + 1) {
					s = s + this.arr[i];
				}
			}
			return s;
		});
		return r;
	}
	replace(): void {
		this.arr = [7];
	}
}

async function main(): Promise<void> {
	const f = new Frozen();
	f.work();
	f.ping();
	const log = await f.dump();
	console.log("send " + log);

	const b = new Borrow();
	const t = b.total();
	b.replace();
	const sum = await t;
	console.log("call sum=" + sum.toString());
	stop(f.pid, ExitReason.Normal);
	stop(b.pid, ExitReason.Normal);
}
main();
