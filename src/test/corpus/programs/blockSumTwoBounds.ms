// @exit: 1
// @stdout: bounded 2997000 1998000
// @stdout: zipped 986184
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the sum wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a reduction bounded by two lengths sums across several 1024-element blocks to the same total as one bound,
// and the overflowing product sum stops with the overflow error.

function filled(count: int32, step: int32): int32[] {
	const out: int32[] = [];
	for (let i: int32 = 0; i < count; i++) out.push((i * step) % 1000);
	return out;
}

function bounded(a: int32[], b: int32[]): int32 {
	let t: int32 = 0;
	let i: int64 = 0;
	while (i < a.length && i < b.length) {
		t += a[i] + b[i];
		i += 1;
	}
	return t;
}

function zipped(a: int32[], b: int32[]): int32 {
	let t: int32 = 0;
	for (const [x, y] of Iterator.zip([a.values(), b.values()])) t += (x * y) & 1023;
	return t;
}

function overflowing(a: int32[], b: int32[]): int32 {
	let t: int32 = 0;
	let i: int64 = 0;
	while (i < a.length && i < b.length) {
		t += a[i] * b[i];
		i += 1;
	}
	return t;
}

const a = filled(3000, 7);
const b = filled(2000, 13);
console.log(`bounded ${bounded(a, a)} ${bounded(b, a)}`);
console.log(`zipped ${zipped(a, b)}`);
const big: int32[] = [];
for (let i: int32 = 0; i < 4000; i++) big.push(40000);
console.log(`${overflowing(big, big)}`);
