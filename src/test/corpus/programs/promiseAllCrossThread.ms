// @stdout: ints 28 order 01234567
// @stdout: strings w0w1w2w3w4w5w6w7
// @stdout: rejects boom
// @stdout: first rejection early
// @stdout: empty 0
// @serial
// note: Promise.all over futures completed on pool threads: later inputs finish first, the result keeps input order, a rejection that lands while slower siblings still run rejects once and those siblings' values are destroyed, repeated 50 times.

function spin(rounds: int32): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < rounds; i++) s += i % 3;
	return s;
}

function slowInt(n: int32): Promise<int32> {
	return spawn((): int32 => { spin((8 - n) * 200000); return n; });
}

function slowWord(n: int32): Promise<string> {
	return spawn((): string => { spin((8 - n) * 200000); return "w" + n.toString(); });
}

function quickBoom(message: string): Promise<string> {
	return spawn((): string => { throw new Error(message); });
}

async function main(): Promise<void> {
	let sum = 0;
	let order = "";
	for (let round = 0; round < 50; round++) {
		const ns = await Promise.all([slowInt(0), slowInt(1), slowInt(2), slowInt(3), slowInt(4), slowInt(5), slowInt(6), slowInt(7)]);
		sum = 0;
		order = "";
		for (const n of ns) { sum += n; order += n.toString(); }
	}
	console.log(`ints ${sum} order ${order}`);
	let text = "";
	for (let round = 0; round < 50; round++) {
		const ws = await Promise.all([slowWord(0), slowWord(1), slowWord(2), slowWord(3), slowWord(4), slowWord(5), slowWord(6), slowWord(7)]);
		text = "";
		for (const w of ws) text += w;
	}
	console.log(`strings ${text}`);
	for (let round = 0; round < 50; round++) {
		try {
			await Promise.all([slowWord(1), slowWord(2), quickBoom("boom"), slowWord(3), slowWord(4), slowWord(5), slowWord(6)]);
			console.log("resolved");
		} catch (e) {
			if (round == 49) console.log(`rejects ${(e as Error).message}`);
		}
	}
	try {
		await Promise.all([slowWord(7), quickBoom("early"), slowWord(0)]);
		console.log("resolved");
	} catch (e) {
		console.log(`first rejection ${(e as Error).message}`);
	}
	const none: Promise<string>[] = [];
	console.log(`empty ${(await Promise.all(none)).length}`);
}

await main();
