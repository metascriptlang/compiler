// @stdout: hit -99
// @stdout: tail 1
// note: two actors call each other while each is frozen in its method, a cycle no reply can end and the
// runtime does not detect while a timer is pending (ULTRALOCK T3). The method that started it races its
// call against a sleep, so its wait ends at the timeout, it replies, and its actor serves the next call.

actor Ping {
	peer: Pong | null = null;
	meet(peer: Pong): void { this.peer = peer; }
	tail(): int32 { return 1; }
	hit(): int32 {
		const got = await Promise.race([this.peer!.back(), late(100)]);
		return got + 1;
	}
}

actor Pong {
	peer: Ping | null = null;
	meet(peer: Ping): void { this.peer = peer; }
	back(): int32 { return (await this.peer!.tail()) + 1; }
}

async function late(ms: int32): Promise<int32> {
	await sleepAsync(ms);
	return -100;
}

async function main(): Promise<void> {
	const ping = new Ping();
	const pong = new Pong();
	ping.meet(pong);
	pong.meet(ping);
	console.log(`hit ${await ping.hit()}`);
	console.log(`tail ${await ping.tail()}`);
}

await main();
