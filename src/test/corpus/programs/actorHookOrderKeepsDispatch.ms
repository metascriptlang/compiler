// @xfail(raiser): the Raiser VM has no actors
// @stdout: before zero=1 one=10 two=300 read=311
// @stdout: between zero=1 one=10 two=300 read=311
// @stdout: after zero=1 one=10 two=300 read=311
// @stdout: done
// @ledger-slack(Before) 1
// @ledger-slack(Between) 1
// @ledger-slack(After) 1
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// note: a lifecycle hook declared before, between or after the message methods leaves every
// message on its own method (old compiler: a hook above a method took that method's message,
// so onTerminate ran with bump's argument as its reason and every later method was shifted by one).

actor Before {
	log: string = "";
	sum: int32 = 0;
	onTerminate(reason: int32): void { console.log(`onTerminate ${reason}`); }
	zero(): void { this.sum += 1; this.log += " zero=1"; }
	one(n: int32): void { this.sum += n; this.log += ` one=${n}`; }
	two(a: int32, b: int32): void { this.sum += a * b; this.log += ` two=${a * b}`; }
	read(): string { return `${this.log} read=${this.sum}`; }
}

actor Between {
	trail: string = "";
	sum: int32 = 0;
	zero(): void { this.sum += 1; this.trail += " zero=1"; }
	one(n: int32): void { this.sum += n; this.trail += ` one=${n}`; }
	onTerminate(reason: int32): void { console.log(`onTerminate ${reason}`); }
	two(a: int32, b: int32): void { this.sum += a * b; this.trail += ` two=${a * b}`; }
	read(): string { return `${this.trail} read=${this.sum}`; }
}

actor After {
	notes: string = "";
	sum: int32 = 0;
	zero(): void { this.sum += 1; this.notes += " zero=1"; }
	one(n: int32): void { this.sum += n; this.notes += ` one=${n}`; }
	two(a: int32, b: int32): void { this.sum += a * b; this.notes += ` two=${a * b}`; }
	read(): string { return `${this.notes} read=${this.sum}`; }
	onTerminate(reason: int32): void { console.log(`onTerminate ${reason}`); }
}

async function main(): Promise<void> {
	const b = new Before();
	b.zero();
	b.one(10);
	b.two(15, 20);
	const br = await b.read();
	console.log(`before${br}`);
	const m = new Between();
	m.zero();
	m.one(10);
	m.two(15, 20);
	const mr = await m.read();
	console.log(`between${mr}`);
	const a = new After();
	a.zero();
	a.one(10);
	a.two(15, 20);
	const ar = await a.read();
	console.log(`after${ar}`);
	console.log("done");
}

await main();
