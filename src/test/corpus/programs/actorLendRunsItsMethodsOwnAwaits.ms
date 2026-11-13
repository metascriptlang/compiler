// @stdout: helper 12 nested 13 then 12 race 2 all 5 tick 1
// note: while a spawn reads a field its actor lent, the lending method awaits an async function, a
// function that awaits another, a .then callback, a race, an all over the spawn itself and a timer.
// Each is work that method started, so it runs beside the lend; only the actor's other work waits for
// the join (ULTRALOCK A4).

function sumN(a: Readonly<int32[]>, rounds: int32): int32 {
	let s: int32 = 0;
	for (let r = 0; r < rounds; r++) for (let i = 0; i < a.length; i++) s = (s + a[i]) % 1000;
	return s;
}

actor Pong {
	back(n: int32): int32 { return n + 1; }
}

async function twoHops(peer: Pong): Promise<int32> {
	const first = await peer.back(10);
	return await peer.back(first);
}

async function deeper(peer: Pong): Promise<int32> {
	return (await twoHops(peer)) + 1;
}

function tick(): Promise<void> {
	return new Promise<void>((done) => { setTimeout(() => { done(); }, 0); });
}

actor Lender {
	arr: int32[] = [1, 2, 3, 4];
	peer: Pong | null = null;
	meet(peer: Pong): void { this.peer = peer; }
	helper(): int32 {
		const sum = spawn((): int32 => sumN(this.arr, 200000));
		const got = await twoHops(this.peer!);
		return got + (await sum);
	}
	nested(): int32 {
		const sum = spawn((): int32 => sumN(this.arr, 200000));
		const got = await deeper(this.peer!);
		return got + (await sum);
	}
	then(): int32 {
		const sum = spawn((): int32 => sumN(this.arr, 200000));
		const got = await this.peer!.back(1).then((v: int32): int32 => v + 10);
		return got + (await sum);
	}
	race(): int32 {
		const sum = spawn((): int32 => sumN(this.arr, 200000));
		const got = await Promise.race([this.peer!.back(1), twoHops(this.peer!)]);
		return got + (await sum);
	}
	all(): int32 {
		const sum = spawn((): int32 => sumN(this.arr, 200000));
		const xs = await Promise.all([sum, this.peer!.back(4)]);
		return xs[0] + xs[1];
	}
	tick(): int32 {
		const sum = spawn((): int32 => sumN(this.arr, 200000));
		await tick();
		return 1 + (await sum);
	}
}

async function main(): Promise<void> {
	const lender = new Lender();
	const pong = new Pong();
	lender.meet(pong);
	const helper = await lender.helper();
	const nested = await lender.nested();
	const then = await lender.then();
	const race = await lender.race();
	const all = await lender.all();
	const tick = await lender.tick();
	console.log(`helper ${helper} nested ${nested} then ${then} race ${race} all ${all} tick ${tick}`);
}

await main();
