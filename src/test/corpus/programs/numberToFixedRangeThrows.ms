// @stdout: 4 of 4 threw RangeError
// @stdout: ok 0 3
// @stdout: ok 100 0.1000000000000000055511151231257827021181583404541015625000000000000000000000000000000000000000000000
// note: toFixed with digits outside 0..100 throws a catchable RangeError with node's message on every backend; the bounds 0 and 100 print.

function digitsOf(n: int32): int32 { return n; }

const message = "toFixed() digits argument must be between 0 and 100";
let rangeErrors = 0;
let attempts = 0;

function attempt(label: string, f: () => string): void {
	attempts += 1;
	try {
		console.log(`${label} returned ${f()}`);
	} catch (e) {
		const kind = e instanceof RangeError ? "RangeError" : "Error";
		console.log(`${label} ${kind} ${e.message}`);
		if (kind == "RangeError" && e.message == message) rangeErrors += 1;
	}
}

const v: number = 0.1;
for (const n of [-1, 101, 1000, -100]) {
	attempt(`digits ${n}`, (): string => v.toFixed(digitsOf(n)));
}
console.log(`${rangeErrors} of ${attempts} threw RangeError`);
console.log(`ok 0 ${(2.5).toFixed(digitsOf(0))}`);
console.log(`ok 100 ${v.toFixed(digitsOf(100))}`);
console.log(`NaN ${(NaN).toFixed(digitsOf(2))}`);
