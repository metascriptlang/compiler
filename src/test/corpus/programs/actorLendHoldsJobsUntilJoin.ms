// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: settleA<resumeA true settleB<resumeB true badTicks 0
// @stdout: ticked: true
// @serial
// note: run() lends its array to two spawned tasks and awaits both. While a lent task is
// still out, or has settled but run() has not resumed past its await, the actor's interval
// tick is held; it runs between visits again once the lend is over (ULTRALOCK A4, T6).
import { stop, ExitReason } from "std/actor";
import { lockedUpdate } from "std/core/promise";

struct Seq { n: number; }
const seq = new Locked<Seq>({ n: 0 });

function ticket(): number {
	let t: number = 0;
	lockedUpdate(seq, (s: Seq): Seq => { t = s.n + 1; return { n: s.n + 1 }; });
	return t;
}

function sumN(a: Readonly<int32[]>, rounds: number): number {
	let s: number = 0;
	for (let r = 0; r < rounds; r++) for (let i = 0; i < a.length; i++) s += a[i];
	return s;
}

actor Lender {
	arr: int32[] = [1, 2, 3, 4];
	ticks: int32 = 0;
	lending: boolean = false;
	badTicks: int32 = 0;
	id: number = 0;
	arm(): int32 {
		this.id = setInterval(() => {
			this.ticks = this.ticks + 1;
			if (this.lending) this.badTicks = this.badTicks + 1;
		}, 1);
		return 1;
	}
	run(): string {
		this.lending = true;
		const a = spawn((): number => { const s = sumN(this.arr, 200000); return s * 1000000 + ticket(); });
		const b = spawn((): number => { const s = sumN(this.arr, 4000000); return s * 1000000 + ticket(); });
		const ra = await a;
		const resumeA = ticket();
		const rb = await b;
		const resumeB = ticket();
		this.lending = false;
		const settleA = ra % 1000000;
		const settleB = rb % 1000000;
		return `settleA<resumeA ${settleA < resumeA} settleB<resumeB ${settleB < resumeB} badTicks ${this.badTicks}`;
	}
	finish(): boolean {
		clearInterval(this.id);
		return this.ticks > 0;
	}
}

async function main(): Promise<void> {
	const l = new Lender();
	await l.arm();
	await sleepAsync(5);
	console.log(await l.run());
	await sleepAsync(5);
	console.log(`ticked: ${await l.finish()}`);
	stop(l.pid, ExitReason.Normal);
}
main();
