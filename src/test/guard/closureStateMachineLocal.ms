// nim-guard: a generator or async local that one state alone touches stays a local of that state,
// so a closure stored in it never keeps the machine's env alive; one that spans a yield or an
// await lives in the machine's env and cycles through it, which orc collects.
//
// Nim: closureiters.nim:1411 detectCapturedSym lifts a local into the iterator env only when a
// second state sees it (varStates); lambdalifting.nim:353 getEnvTypeForOwner gives a closure made
// in the iterator the iterator's own env. Measured with the built nim (--mm:arc vs --mm:orc,
// 20000 runs): a closure held across a yield grows 960016 bytes under arc and is collected under
// orc; a closure made and used after the yield grows 16 bytes on both. NIM-REF: TR-11.
//
// RED MEANS a one-state local holding a closure was moved into the machine's env (drc leak), a
// cycle through the machine's env is not collected under orc, or a closure lost a write to the
// machine's variable — run /trace-nim on generatorLower's localsSpanningStates.
//
// GUARD-BALANCE dollarEnv_smOneState_shared_
// GUARD-BALANCE dollarEnv_smAsyncOneState_shared_
// GUARD-BALANCE-ORC dollarEnv_smSpanning_shared_
// GUARD-JS

function* smSpanning(): Iterator<int32> {
	let seen: int32 = 0;
	const bump = (): void => { seen = seen + 1; };
	yield 1;
	bump();
	yield seen;
}

function* smOneState(): Iterator<int32> {
	let seen: int32 = 0;
	yield 1;
	const bump = (): void => { seen = seen + 1; };
	bump();
	yield seen;
}

async function smWork(x: int32): Promise<int32> {
	return x;
}

async function smAsyncOneState(): Promise<int32> {
	let total: int32 = 0;
	const v = await smWork(3);
	const add = (k: int32): void => { total = total + k; };
	add(v);
	add(v);
	return total;
}

async function main(): Promise<void> {
	let spanning: int32 = 0;
	let oneState: int32 = 0;
	let asyncOne: int32 = 0;
	for (let n: int32 = 0; n < 200; n++) {
		for (const v of smSpanning()) spanning = spanning + v;
		for (const v of smOneState()) oneState = oneState + v;
		asyncOne = asyncOne + await smAsyncOneState();
	}
	console.log(`spanning=${spanning} oneState=${oneState} asyncOne=${asyncOne}`);
	if (spanning != 400) throw "GUARD RED: a closure held across a yield lost its write, got=" + spanning.toString();
	if (oneState != 400) throw "GUARD RED: a closure made after a yield lost its write, got=" + oneState.toString();
	if (asyncOne != 1200) throw "GUARD RED: a closure made after an await lost its write, got=" + asyncOne.toString();
	console.log("GUARD-OK");
}
await main();
