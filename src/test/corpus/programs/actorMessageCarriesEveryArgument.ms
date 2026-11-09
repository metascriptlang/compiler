// @stdout: sent 7 strings 200 times, joined length 8200
// @stdout: called with 7 strings, joined a-1|b-1|c-1|d-1|e-1|f-1|g-1
// note: a string fills two message slots, so seven string arguments need 14 slots. The old
//   message pool gave the largest method 13 and the sender wrote the last string past its
//   envelope, over the next free envelope's link. An envelope is now sized by its arguments.

actor Joiner {
	total: int32 = 0;
	take(a: string, b: string, c: string, d: string, e: string, f: string, g: string): void {
		this.total += `${a}|${b}|${c}|${d}|${e}|${f}|${g}`.length;
	}
	join(a: string, b: string, c: string, d: string, e: string, f: string, g: string): string {
		return `${a}|${b}|${c}|${d}|${e}|${f}|${g}`;
	}
	totalSoFar(): int32 { return this.total; }
}

function tagged(name: string, i: int32): string {
	return `${name}-${i}`;
}

async function run(): Promise<void> {
	const j = new Joiner();
	for (let i: int32 = 100; i < 300; i++) {
		j.take(tagged("a", i), tagged("b", i), tagged("c", i), tagged("d", i), tagged("e", i), tagged("f", i), tagged("g", i));
	}
	console.log(`sent 7 strings 200 times, joined length ${await j.totalSoFar()}`);
	const joined = await j.join(tagged("a", 1), tagged("b", 1), tagged("c", 1), tagged("d", 1), tagged("e", 1), tagged("f", 1), tagged("g", 1));
	console.log(`called with 7 strings, joined ${joined}`);
}

await run();
