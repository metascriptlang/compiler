// @stdout: all 5 stored 5 mixed 14 fns 24 race 2 any 6 settled 7 again 5
// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// note: an actor method awaits Promise.all, race, any and allSettled over calls into another actor and
// over async functions it started. The combinator's work on each input runs as the awaiting actor's job,
// where the inputs' counts live (ULTRALOCK A4, M1); the race's losing input settles after its method ended.

actor Pong {
	back(n: int32): int32 { return n + 1; }
}

async function twoHops(peer: Pong): Promise<int32> {
	const first = await peer.back(10);
	return await peer.back(first);
}

async function boom(): Promise<int32> {
	throw new Error("boom");
}

actor Ping {
	peer: Pong | null = null;
	meet(peer: Pong): void { this.peer = peer; }
	all(): int32 {
		const xs = await Promise.all([this.peer!.back(1), this.peer!.back(2)]);
		return xs[0] + xs[1];
	}
	stored(): int32 {
		const both = Promise.all([this.peer!.back(1), this.peer!.back(2)]);
		const xs = await both;
		return xs[0] + xs[1];
	}
	mixed(): int32 {
		const xs = await Promise.all([this.peer!.back(1), twoHops(this.peer!)]);
		return xs[0] + xs[1];
	}
	fns(): int32 {
		const xs = await Promise.all([twoHops(this.peer!), twoHops(this.peer!)]);
		return xs[0] + xs[1];
	}
	race(): int32 {
		return await Promise.race([this.peer!.back(1), twoHops(this.peer!)]);
	}
	any(): int32 {
		return await Promise.any([boom(), this.peer!.back(5)]);
	}
	settled(): int32 {
		await Promise.allSettled([this.peer!.back(1), boom()]);
		return 7;
	}
}

async function main(): Promise<void> {
	const ping = new Ping();
	const pong = new Pong();
	ping.meet(pong);
	const all = await ping.all();
	const stored = await ping.stored();
	const mixed = await ping.mixed();
	const fns = await ping.fns();
	const race = await ping.race();
	const any = await ping.any();
	const settled = await ping.settled();
	const again = await ping.all();
	console.log(`all ${all} stored ${stored} mixed ${mixed} fns ${fns} race ${race} any ${any} settled ${settled} again ${again}`);
}

await main();
