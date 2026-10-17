// @stdout: n 5000 sum -250 -250 29 drain 250 dot 21070 -21070 i8 -1 i16 0 10000 i64 -10000000000000 20005000000000000 wide -250
// @stdout: alternating 2147483647 0 -2147483647 9223372036854775807 wide 2147483647
// @stdout: wide max 10737418235000
// note: reductions over arrays of 0, 1, 1023, 1024, 1025 and 5000 elements give the exact sum on every width, for-of and
// indexed, += and -=, and a dot product; blocks of large alternating values the guard refuses fall back and stay exact.

function sumOf32(xs: int32[]): int32 {
	let s: int32 = 0;
	for (const x of xs) s += x;
	return s;
}

function sumAt32(xs: int32[], from: int32): int32 {
	let s: int32 = 0;
	for (let i = from; i < xs.length; i++) s += xs[i];
	return s;
}

function drain32(xs: int32[]): int32 {
	let s: int32 = 0;
	for (const x of xs) s -= x;
	return s;
}

function dot32(a: int32[], b: int32[]): int32 {
	let s: int32 = 0;
	for (let k = 0; k < a.length; k++) s += a[k] * b[k];
	return s;
}

function undot32(a: int32[], b: int32[]): int32 {
	let s: int32 = 0;
	for (let k = 0; k < a.length; k++) s -= a[k] * b[k];
	return s;
}

function sumOf8(xs: int8[]): int8 {
	let s: int8 = 0;
	for (const x of xs) s += x;
	return s;
}

function dot16(a: int16[], b: int16[]): int16 {
	let s: int16 = 0;
	for (let k = 0; k < a.length; k++) s += a[k] * b[k];
	return s;
}

function sumOf16(xs: int16[]): int16 {
	let s: int16 = 0;
	for (let i: int64 = 0; i < xs.length; i++) s += xs[i];
	return s;
}

function sumOf64(xs: int64[]): int64 {
	let s: int64 = 0;
	for (const x of xs) s += x;
	return s;
}

function dot64(a: int64[], b: int64[]): int64 {
	let s: int64 = 0;
	for (let k = 0; k < a.length; k++) s += a[k] * b[k];
	return s;
}

function wide(xs: int32[]): int64 {
	let s: int64 = 0;
	for (const x of xs) s += x;
	return s;
}

function main(): void {
	const lengths: int32[] = [0, 1, 1023, 1024, 1025, 5000];
	for (const n of lengths) {
		const xs: int32[] = [];
		const ys: int32[] = [];
		const bs: int8[] = [];
		const hs: int16[] = [];
		const ls: int64[] = [];
		const ms: int64[] = [];
		for (let i = 0; i < n; i++) {
			xs.push((i * 7) % 201 - 100);
			ys.push((i * 13) % 101 - 50);
			bs.push(((i % 3) - 1) as int8);
			hs.push(((i % 5) - 2) as int16);
			ls.push((((i % 9) as int64) - 4) * 1000000000000);
			ms.push((((i % 7) as int64) - 3) * 1000000);
		}
		console.log(`n ${n} sum ${sumOf32(xs)} ${sumAt32(xs, 0)} ${sumAt32(xs, 3)} drain ${drain32(xs)} dot ${dot32(xs, ys)} ${undot32(xs, ys)} i8 ${sumOf8(bs)} i16 ${sumOf16(hs)} ${dot16(hs, hs)} i64 ${sumOf64(ls)} ${dot64(ms, ms)} wide ${wide(xs)}`);
	}
	const big: int32[] = [];
	const big64: int64[] = [];
	for (let i = 0; i < 3001; i++) {
		big.push(i % 2 == 0 ? 2147483647 : -2147483647);
		big64.push(i % 2 == 0 ? 9223372036854775807 : -9223372036854775807);
	}
	console.log(`alternating ${sumOf32(big)} ${sumAt32(big, 1)} ${drain32(big)} ${sumOf64(big64)} wide ${wide(big)}`);
	const tall: int32[] = [];
	for (let i = 0; i < 5000; i++) tall.push(2147483647);
	console.log(`wide max ${wide(tall)}`);
}

main();
