// @stdout: 4 of 4 threw RangeError | bigint 36 73 | bigint 2 -11111111
// @xfail(raiser): bigint is not supported on the Raiser VM
// note: a bigint toString(radix) with a radix outside 2..36 throws a catchable RangeError with node's message on C and JS; C used to abort with exit 134, and JS threw the engine's error, which is not the RangeError class.

function radixOf(n: int32): int32 { return n; }

const message = "toString() radix argument must be between 2 and 36";
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

const big: bigint = 255n;
const radixes: int32[] = [1, 37, 0, -5];
for (const r of radixes) {
	attempt(`bigint ${r}`, (): string => big.toString(radixOf(r)));
}
console.log(`${rangeErrors} of ${attempts} threw RangeError | bigint 36 ${big.toString(radixOf(36))} | bigint 2 ${(-big).toString(radixOf(2))}`);
