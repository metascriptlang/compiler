// @stdout: static member namespace ok

// A static member (`this typeof T`) belongs to its receiver type, never to the
// module scope: `Math.abs(x)` resolves, a bare `abs(x)` is an undefined name.
// An instance extension (`this v: T`) keeps both forms, so the two can share a
// name without colliding. Both backends must agree on every line.

class Unit {}

function scale(this typeof Unit, v: float64): float64 { return v * 2.0; }

function widen(this s: string): int32 { return s.length; }

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function main(): int32 {
	let pass = true;

	// Prelude statics reach only through their receiver.
	pass = check("mathAbs", Math.abs(-1.5) === 1.5) && pass;
	pass = check("mathFloor", Math.floor(3.7) === 3.0) && pass;
	pass = check("numberIsInteger", Number.isInteger(5)) && pass;
	pass = check("stringFromCharCode", String.fromCharCode(72) === "H") && pass;
	pass = check("bigintAsUintN", BigInt.asUintN(8, 255n + 1n) === 0n) && pass;

	// A user namespace behaves the same way.
	pass = check("userStatic", Unit.scale(2.5) === 5.0) && pass;

	// An instance extension keeps both call forms.
	pass = check("instanceReceiver", "abcd".widen() === 4) && pass;
	pass = check("instanceFree", widen("abc") === 3) && pass;

	// The prelude's own instance extensions keep the free-call form.
	pass = check("preludeUfcsFree", parseFloat("1.5") === 1.5) && pass;
	pass = check("preludeUfcsReceiver", "2.5".parseFloat() === 2.5) && pass;

	if (!pass) { return 1; }
	console.log("static member namespace ok");
	return 0;
}

const rc = main();
if (rc !== 0) { process.exit(rc); }
