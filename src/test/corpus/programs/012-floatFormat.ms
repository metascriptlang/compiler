// Parity program — float→string must be byte-identical on C and JS, because
// every future corpus program that prints a float depends on it. The C runtime
// implements the ECMAScript Number::toString algorithm (shortest round-trip,
// exponential below 1e-6 and at/above 1e21, whole floats without a fraction),
// NOT printf %g. Probed 2026-07-30: all cases below already agree; this pins
// that so it cannot drift silently and force normalization in the runner.
// The boundary cases are the contract — do not "simplify" them away.

function show(label: string, v: float64): void {
	console.log(label + "=" + v.toString());
}

function main(): void {
	show("whole1", 1.0);
	show("whole2", 42.0);
	show("negwhole", -7.0);
	show("simple", 3.14);
	show("tenth", 0.1);
	show("sum", 0.1 + 0.2);
	show("third", 1.0 / 3.0);
	show("neg", -2.5);
	show("zero", 0.0);
	show("small6", 0.000001);
	show("small7", 0.0000001);
	show("big20", 100000000000000000000.0);
	show("big21", 1000000000000000000000.0);
	show("halfway", 2.5);
	show("halfway2", 3.5);
	show("tiny", 5.0e-324);
	show("maxsafe", 9007199254740991.0);
	show("bigexp", 1.0e100);
	show("prec17", 0.30000000000000004);
	show("e5", 123456.789);
}
main();
