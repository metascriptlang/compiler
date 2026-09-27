// nim-guard: a nested routine that calls itself is never a field of its own env.
//
// Nim: lambdalifting.nim:203 interestingVar captures only variables and params;
// symToClosure (:761) builds a routine's reference to itself as a closure over
// its own hidden env param. Nim test: tests/closure/tnested.nim, outer2.fac.
// NIM-REF: TR-11.
//
// RED MEANS a self-recursive nested function or const arrow is stored in its
// owner's env again (env -> closure -> env, leaked on every call) — run
// /trace-nim on lambda lifting's routine self-references.
//
// GUARD-BALANCE dollarEnv_srCapture_shared_
// GUARD-BALANCE dollarEnv_srNoCapture_shared_
// GUARD-BALANCE dollarEnv_srArrow_shared_
// GUARD-BALANCE dollarEnv_srMake_shared_
// GUARD-JS

function srCapture(): int32 {
	let total: int32 = 0;
	function add(k: int32): void {
		total = total + k;
		if (k > 0) add(k - 1);
	}
	add(3);
	return total;
}

function srNoCapture(): int32 {
	let calls: int32 = 0;
	const bump = (): void => { calls = calls + 1; };
	function fact(k: int32): int32 {
		if (k <= 1) return 1;
		return k * fact(k - 1);
	}
	bump();
	return fact(5) + calls;
}

function srArrow(): int32 {
	const base: int32 = 10;
	const walk = (k: int32): int32 => k <= 0 ? base : walk(k - 1) + 1;
	return walk(3);
}

function srMake(): (k: int32) => int32 {
	const base: int32 = 100;
	function climb(k: int32): int32 {
		return k <= 0 ? base : climb(k - 1) + 1;
	}
	return climb;
}

function main(): void {
	let capture: int32 = 0;
	let noCapture: int32 = 0;
	let arrow: int32 = 0;
	let escaped: int32 = 0;
	for (let i: int32 = 0; i < 200; i++) {
		capture = capture + srCapture();
		noCapture = noCapture + srNoCapture();
		arrow = arrow + srArrow();
		const climb = srMake();
		escaped = escaped + climb(3);
	}
	console.log(`capture=${capture} noCapture=${noCapture} arrow=${arrow} escaped=${escaped}`);
	if (capture != 1200) throw "GUARD RED: a recursive nested function lost its captured writes, got=" + capture.toString();
	if (noCapture != 24200) throw "GUARD RED: a recursive nested function without captures computed a wrong value, got=" + noCapture.toString();
	if (arrow != 2600) throw "GUARD RED: a recursive const arrow computed a wrong value, got=" + arrow.toString();
	if (escaped != 20600) throw "GUARD RED: a recursive routine called after its owner returned computed a wrong value, got=" + escaped.toString();
	console.log("GUARD-OK");
}
main();
