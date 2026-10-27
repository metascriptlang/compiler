// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: total 108 total2 233 total3 2
// @serial

enum Kind {
	A,
	B,
}

actor Runner {
	total: int64 = 0;

	run(first: int64, kind: Kind | null, tail: Vec<uint8>): int64 {
		this.total += first + tail.length;
		if (kind !== null) { this.total += 100; }
		return this.total;
	}

	runTwo(kind: Kind | null, extra: int64 | null, tail: Vec<uint8>): int64 {
		this.total += tail.length;
		if (kind !== null) { this.total += 100; }
		if (extra !== null) { this.total += extra; }
		return this.total;
	}
}

async function drive(runner: Runner, kind: Kind | null): Promise<int64> {
	let tail: Vec<uint8> = [1, 2, 3];
	return await runner.run(5, kind, move tail);
}

async function driveTwo(runner: Runner, kind: Kind | null, extra: int64 | null): Promise<int64> {
	let tail: Vec<uint8> = [1, 2];
	return await runner.runTwo(kind, extra, move tail);
}

async function main(): Promise<void> {
	const runner = new Runner();
	const total = await drive(runner, Kind.A);
	const two = await driveTwo(new Runner(), Kind.B, 131);
	const three = await driveTwo(new Runner(), null, null);
	console.log(`total ${total} total2 ${two} total3 ${three}`);
}

await main();
