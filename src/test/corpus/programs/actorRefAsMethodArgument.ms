// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: void 1 value 2 reply 2
// @serial
actor Relay {
	hits: int32 = 0;
	peer: Relay | null = null;
	hit(): void {
		this.hits = this.hits + 1;
	}
	link(p: Relay): void {
		this.peer = p;
	}
	linkValue(p: Relay): int32 {
		this.peer = p;
		return 2;
	}
	poke(): int32 {
		const p = this.peer;
		if (p != null) p.hit();
		return this.hits;
	}
	count(): int32 {
		return this.hits;
	}
}

async function main(): Promise<void> {
	const a = new Relay();
	const b = new Relay();
	a.link(b);
	await a.poke();
	const viaVoid = await b.count();
	const reply = await a.linkValue(b);
	await a.poke();
	const viaValue = await b.count();
	console.log(`void ${viaVoid} value ${viaValue} reply ${reply}`);
}

await main();
