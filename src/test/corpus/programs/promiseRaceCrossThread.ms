// @stdout: int winners 100 of 100
// @stdout: string winner one of its inputs
// @stdout: struct winner one of its inputs
// @stdout: any winner one of its inputs
// @stdout: race ends with the first to settle
// @serial
// note: Promise.race and Promise.any over two inputs completed on pool threads: exactly one input wins (which one depends on the backend: js runs a spawned body inline), the slower one's value is destroyed once (SAN ledger clean), repeated 50 times for an int32, a string and a struct element.

struct Pt { name: string; n: int32; }

function spin(rounds: int32): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < rounds; i++) s += i % 3;
	return s;
}

function intAfter(n: int32, rounds: int32): Promise<int32> {
	return spawn((): int32 => { spin(rounds); return n; });
}

function wordAfter(w: string, rounds: int32): Promise<string> {
	return spawn((): string => { spin(rounds); return w + ""; });
}

function pointAfter(w: string, n: int32, rounds: int32): Promise<Pt> {
	return spawn((): Pt => { spin(rounds); return { name: w + "", n: n }; });
}

function boomAfter(message: string, rounds: int32): Promise<string> {
	return spawn((): string => { spin(rounds); throw new Error(message); });
}

async function main(): Promise<void> {
	let ints = 0;
	for (let round = 0; round < 50; round++) {
		const n = await Promise.race([intAfter(1, 4000000), intAfter(2, 10)]);
		if (n == 1 || n == 2) ints = ints + 1;
		const m = await Promise.race([intAfter(1, 10), intAfter(2, 4000000)]);
		if (m == 1 || m == 2) ints = ints + 1;
	}
	console.log(`int winners ${ints} of 100`);
	let word = "";
	for (let round = 0; round < 50; round++) {
		word = await Promise.race([wordAfter("slow", 4000000), wordAfter("fast", 10)]);
	}
	console.log(word == "fast" || word == "slow" ? "string winner one of its inputs" : "string winner " + word);
	let pt: Pt = { name: "", n: 0 };
	for (let round = 0; round < 50; round++) {
		pt = await Promise.race([pointAfter("p2", 5, 4000000), pointAfter("p1", 4, 10)]);
	}
	console.log((pt.name == "p1" && pt.n == 4) || (pt.name == "p2" && pt.n == 5) ? "struct winner one of its inputs" : `struct winner ${pt.name} ${pt.n}`);
	for (let round = 0; round < 50; round++) {
		word = await Promise.any([wordAfter("slow", 4000000), wordAfter("fast", 10)]);
	}
	console.log(word == "fast" || word == "slow" ? "any winner one of its inputs" : "any winner " + word);
	let reason = "";
	for (let round = 0; round < 50; round++) {
		try {
			await Promise.race([wordAfter("slow", 4000000), boomAfter("quick", 10)]);
		} catch (e) {
			reason = (e as Error).message;
		}
	}
	console.log(reason == "" || reason == "quick" ? "race ends with the first to settle" : "race rejection " + reason);
}

await main();
