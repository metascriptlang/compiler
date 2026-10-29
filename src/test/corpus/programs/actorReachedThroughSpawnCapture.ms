// @stdout: sum 7 read 7
// @serial
actor Tally {
	n: int32 = 0;
	add(x: int32): void {
		this.n = this.n + x;
	}
	get(): int32 {
		return this.n;
	}
}

async function main(): Promise<void> {
	const tallies: Tally[] = [new Tally()];
	const first = spawn(() => { tallies[0].add(3); return 0; });
	const second = spawn(() => { tallies[0].add(4); return 0; });
	await first;
	await second;
	const read = await spawn(() => await tallies[0].get());
	console.log(`sum ${await tallies[0].get()} read ${read}`);
}

await main();
