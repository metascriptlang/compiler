// @stdout: got 7
// @stdout: started 2
// note: a spawn handle an actor keeps in a field is a future its visit made, so the actor owns it (ULTRALOCK M1); the actor's teardown at exit releases it as that actor, whether the handle was awaited or never read.

actor Awaited {
	h: Promise<number> | null = null;

	start(): void {
		this.h = spawn((): number => 7);
	}

	get(): number {
		return await this.h!;
	}
}

actor NeverRead {
	h: Promise<number> | null = null;

	start(n: number): void {
		this.h = spawn((): number => n);
	}
}

const a = new Awaited();
a.start();
console.log(`got ${await a.get()}`);
const b = new NeverRead();
b.start(2);
console.log("started 2");
