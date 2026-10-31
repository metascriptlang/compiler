// @stdout: then 42 s:pool p:7:pool | catch 42 s:pool p:7 rescued 5 | finally 42 s:pool p:7:pool 3 | chain 43 e:boom
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: the input of a then, catch or finally completes on a pool thread, so the callback runs on
// the awaiting thread with a value the pool wrote: an int32, a string and a struct through then,
// the same three through catch and finally on success, a pool rejection through catch, and a
// then chain whose second link reads what the first one stored and whose rejection skips the
// then callbacks and reaches the catch.

struct Pair { n: int32; tag: string; }

function poolNum(): int32 { return 42; }
function poolText(): string { return "s:" + "pool"; }
function poolPair(): Pair { return { n: 7, tag: "p:7:pool" }; }
function poolBoom(): int32 { throw new Error("boom"); }

async function run(): Promise<void> {
	let thenNum: int32 = 0;
	let thenText = "";
	let thenPair = "";
	await spawn(poolNum).then((v: int32): void => { thenNum = v; });
	await spawn(poolText).then((v: string): void => { thenText = v; });
	await spawn(poolPair).then((v: Pair): void => { thenPair = v.tag; });
	const out1 = `then ${thenNum} ${thenText} ${thenPair}`;

	const cNum: int32 = await spawn(poolNum).catch((e: Error): int32 => -1);
	const cText: string = await spawn(poolText).catch((e: Error): string => "no");
	const cPair: Pair = await spawn(poolPair).catch((e: Error): Pair => ({ n: 0, tag: "no" }));
	const rescued: int32 = await spawn(poolBoom).catch((e: Error): int32 => 5);
	const out2 = `catch ${cNum} ${cText} p:${cPair.n} rescued ${rescued}`;

	let ran = 0;
	const fNum: int32 = await spawn(poolNum).finally(() => { ran += 1; });
	const fText: string = await spawn(poolText).finally(() => { ran += 1; });
	const fPair: Pair = await spawn(poolPair).finally(() => { ran += 1; });
	const out3 = `finally ${fNum} ${fText} ${fPair.tag} ${ran}`;

	let stored: int32 = 0;
	let chained: int32 = 0;
	let message = "";
	const first = spawn(poolNum).then((v: int32): void => { stored = v + 1; });
	await first.then((): void => { chained = stored; });
	await spawn(poolBoom).then((v: int32): void => { stored = -1; }).catch((e: Error): void => { message = e.message; });
	const out4 = `chain ${chained} e:${message}`;
	console.log(`${out1} | ${out2} | ${out3} | ${out4}`);
}

await run();
