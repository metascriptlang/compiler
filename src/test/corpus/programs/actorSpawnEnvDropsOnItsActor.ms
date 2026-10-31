// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: lend 5 direct 2 loop 9
// note: a spawn started in an actor method holds the method's env until the task settles;
// that env is the actor's cell, so its release runs in one of the actor's visits, not on
// the loop of the thread that submitted it (ULTRALOCK M1, A4). A try with a catch makes the
// env cyclic, which the owner check at free reports when another executor frees it.

actor Lender {
	arr: int32[] = [1, 2, 3, 4];

	lend(): string {
		try {
			const a = spawn((): number => this.arr.length);
			const b = spawn((): number => this.arr[0]);
			const ra = await a;
			const rb = await b;
			return `lend ${ra + rb}`;
		} catch (e) {
			return `caught ${e.message}`;
		}
	}

	direct(): string {
		try {
			const r = await spawn((): number => this.arr[1]);
			return `direct ${r}`;
		} catch (e) {
			return `caught ${e.message}`;
		}
	}

	loop(): string {
		try {
			const hs: Promise<number>[] = [];
			for (let i = 0; i < 3; i++) hs.push(spawn((): number => this.arr[2]));
			let sum: number = 0;
			for (const h of hs) sum += await h;
			return `loop ${sum}`;
		} catch (e) {
			return `caught ${e.message}`;
		}
	}
}

async function main(): Promise<void> {
	const l = new Lender();
	let s = "";
	for (let i = 0; i < 40; i++) s = `${await l.lend()} ${await l.direct()} ${await l.loop()}`;
	console.log(s);
}
await main();
