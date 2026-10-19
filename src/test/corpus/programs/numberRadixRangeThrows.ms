// @stdout: 24 of 24 threw RangeError | float64 16 ff.8 | int64 2 -11111111 | int32 2 -11111111 | uint64 36 3w5e11264sgsf
// note: toString(radix) with a radix outside 2..36 throws a catchable RangeError with node's message on every backend; C and JS used to stop the program.

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

const f64: float64 = 255.5;
const f32: float32 = 1.5;
const i32: int32 = -255;
const u8: uint8 = 200;
const i64: int64 = -255;
const u64: uint64 = 18446744073709551615;
const radixes: int32[] = [1, 37, 0, -5];

for (const r of radixes) {
	attempt(`float64 ${r}`, (): string => f64.toString(radixOf(r)));
	attempt(`float32 ${r}`, (): string => f32.toString(radixOf(r)));
	attempt(`int32 ${r}`, (): string => i32.toString(radixOf(r)));
	attempt(`uint8 ${r}`, (): string => u8.toString(radixOf(r)));
	attempt(`int64 ${r}`, (): string => i64.toString(radixOf(r)));
	attempt(`uint64 ${r}`, (): string => u64.toString(radixOf(r)));
}
console.log(`${rangeErrors} of ${attempts} threw RangeError | float64 16 ${f64.toString(radixOf(16))} | int64 2 ${i64.toString(radixOf(2))} | int32 2 ${i32.toString(radixOf(2))} | uint64 36 ${u64.toString(radixOf(36))}`);
