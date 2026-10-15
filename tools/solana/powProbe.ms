import { instructionData, logU64 } from "std/solana";

const TWO_POW_52: float64 = 4503599627370496.0;

function bitsOf(v: float64): uint64 {
	if (v != v) return 0x7ff8000000000000;
	let sign: uint64 = 0;
	let a = v;
	if (a < 0.0 || (a == 0.0 && 1.0 / a < 0.0)) {
		sign = 0x8000000000000000;
		a = -a;
	}
	if (a == Infinity) return sign | 0x7ff0000000000000;
	if (a == 0.0) return sign;
	let e: int64 = 0;
	while (a >= 2.0) { a = a / 2.0; e++; }
	while (a < 1.0 && e > -1022) { a = a * 2.0; e--; }
	if (a < 1.0) return sign | ((a * TWO_POW_52) as uint64);
	return sign | (((e + 1023) as uint64) << 52) | (((a - 1.0) * TWO_POW_52) as uint64);
}

function main(): void {
	const xs: float64[] = [2.0, 3.0, 0.3, 1.1, 7.0, 49.283038373705544, 1e-300, 1e300, 0.0, -0.0, -8.0, 1.0, -1.0, Infinity, -Infinity, NaN, 10.0, 3.141592653589793];
	const ys: float64[] = [0.5, 1.5, 37.0, 37.0, -0.5, 1.5, 0.5, -0.5, -0.5, -0.5, 1.0 / 3.0, NaN, Infinity, -0.5, 1.5, 0.0, -1074.0, 2.718281828459045];
	const data = instructionData();
	const op = data.readU8(0);
	const at = data.readU8(1);
	if (!op.ok || !at.ok) { return; }
	const x = xs[at.value as int64];
	if (op.value == 0) { logU64(bitsOf(x ** 1.5)); }
	if (op.value == 1) { logU64(bitsOf(x ** 37)); }
	if (op.value == 2) { logU64(bitsOf(x ** -0.5)); }
	if (op.value == 3) { logU64(bitsOf(Math.pow(x, ys[at.value as int64]))); }
}
main();
