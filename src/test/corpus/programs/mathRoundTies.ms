// @stdout: math round done
// note: Math.round rounds half toward +Infinity, keeps the sign of a zero
// and is exact past 2^52, as TS does.

function show(v: float64): string {
	return v == 0.0 && Math.atan2(v, -1.0) < 0.0 ? "-0" : `${v}`;
}

let failures = 0;

function check(what: string, i: int32, got: string, want: string): void {
	if (got != want) {
		console.log(`FAIL ${what}[${i}] got ${got} want ${want}`);
		failures += 1;
	}
}

const roundInputs: float64[] = [
	0.49999999999999994,
	-0.49999999999999994,
	0.5,
	-0.5,
	1.5,
	-1.5,
	2.5,
	-2.5,
	4503599627370497.0,
	-4503599627370497.0,
	4503599627370495.5,
	-4503599627370495.5,
	9007199254740991.0,
	1e+300,
	-1e+300,
	-0.0,
	0.0,
	Number.NaN,
	Number.POSITIVE_INFINITY,
	Number.NEGATIVE_INFINITY,
	-0.2,
	0.2,
	2.4999999999999996,
	-2.5000000000000004,
	1.7976931348623157e+308,
	5e-324,
	-5e-324,
	0.7,
	-0.7,
	123.5,
	-123.5,
	2.5000000000000004,
	-2.4999999999999996,
];
const roundWant: string[] = [
	"0",
	"-0",
	"1",
	"-0",
	"2",
	"-1",
	"3",
	"-2",
	"4503599627370497",
	"-4503599627370497",
	"4503599627370496",
	"-4503599627370495",
	"9007199254740991",
	"1e+300",
	"-1e+300",
	"-0",
	"0",
	"NaN",
	"Infinity",
	"-Infinity",
	"-0",
	"0",
	"2",
	"-3",
	"1.7976931348623157e+308",
	"0",
	"-0",
	"1",
	"-1",
	"124",
	"-123",
	"3",
	"-2",
];

for (let i = 0; i < roundInputs.length; i++) {
	check("Math.round", i, show(Math.round(roundInputs[i])), roundWant[i]);
}
console.log(failures == 0 ? "math round done" : `${failures} failures`);
