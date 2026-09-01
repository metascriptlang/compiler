// @maxrss: 30
// @stdout: closure-array acc=
// note: bug033 native repro: array of closures freed at scope exit. Was a misaligned-access crash; runs through C DRC here (the inline-test tier never touched the crash path).

// bug033 native repro — array of closures freed at scope exit.
//
// Original symptom: a function returning `(() => T)[]` printed correct values
// then PANICKED on cleanup (misaligned msRefHeader access — msArrayRefDestroy
// read inline 16B msClosure structs as 8B void*). The existing fixedbugs/bug033
// inline "no crash" test never executes the C destroy path — so it
// guards nothing for the actual fix. This runs the real native binary through
// C DRC, where the crash actually lived. Looped so a regression also shows as
// RSS growth, not just a one-shot crash. Accumulator bounded (% ...) so a
// signed-overflow UBSan trap can never masquerade as a DRC crash.

function makeFns(base: int32): (() => int32)[] {
	const fns: (() => int32)[] = [];
	let k = 0;
	while (k < 8) {
		const x = (base + (k as int32)) % 100;
		fns.push(() => x);
		k = k + 1;
	}
	return fns;
}

function main(): void {
	let acc: int32 = 0 as int32;
	let i = 0;
	while (i < 200000) {
		const fns = makeFns(i as int32);            // array of closures
		for (const f of fns) { acc = (acc + f()) % 1000; }  // scope exit destroys fns → was the crash
		i = i + 1;
	}
	console.log(`closure-array acc=${acc}`);
}

main();
