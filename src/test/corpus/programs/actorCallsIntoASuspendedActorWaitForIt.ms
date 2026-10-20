// @serial
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: during m-start;m-end 5;
// @stdout: after m-start;m-end 5;note;y;
// @stdout: nap m-start;m-end 5;note;y;nap-end;
// @stdout: got 7
// @stdout: final m-start;m-end 5;note;y;nap-end;y;
// note: a send or call that reaches an actor while one of its methods awaits runs after
//   that method has finished (PARALOCK §14 for an awaited CALL and a timer; 1113 pins the
//   spawn await). A call back into the waiting actor completes then, both when the callee
//   leaves it unawaited and when the callee awaits it while the actor waits on a timer:
//   neither is a deadlock.

actor A {
	log: string = "";
	b: B | null = null;
	attach(b: B): int32 {
		this.b = b;
		return 0;
	}
	m(): string {
		const b = this.b;
		if (b == null) return "none";
		this.log = this.log + "m-start;";
		const v = await b.x();
		this.log = this.log + "m-end " + v.toString() + ";";
		return this.log;
	}
	napThenEnd(): string {
		const b = this.b;
		if (b == null) return "none";
		b.kick();
		await sleepAsync(5);
		this.log = this.log + "nap-end;";
		return this.log;
	}
	note(): void {
		this.log = this.log + "note;";
	}
	y(): int32 {
		this.log = this.log + "y;";
		return 7;
	}
	dump(): string {
		return this.log;
	}
}

actor B {
	a: A | null = null;
	got: int32 = 0;
	attach(a: A): int32 {
		this.a = a;
		return 0;
	}
	x(): int32 {
		const a = this.a;
		if (a == null) return -1;
		a.note();
		a.y();
		return 5;
	}
	kick(): void {
		const a = this.a;
		if (a == null) return;
		this.got = await a.y();
	}
	read(): int32 {
		return this.got;
	}
}

const a = new A();
const b = new B();
await a.attach(b);
await b.attach(a);
const during = await a.m();
console.log("during " + during);
console.log("after " + (await a.dump()));
const napped = await a.napThenEnd();
console.log("nap " + napped);
console.log("got " + (await b.read()).toString());
console.log("final " + (await a.dump()));
