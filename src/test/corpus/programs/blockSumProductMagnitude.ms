// @exit: 1
// @stdout: small 250000500
// @stdout: wide 1096704000
// @stdout: extremes 1073741824 1073709021
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the product wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a sum of products of two varying int32 operands gives the checked loop's total when the operands are small,
// when their magnitudes are too wide to prove every product fits but each still does, and at -32768 * -32768;
// a product past int32 stops with the overflow error.

function dot(a: int32[], b: int32[]): int32 {
	let t: int32 = 0;
	for (const [x, y] of Iterator.zip([a.values(), b.values()])) t += (x * y) & 1048575;
	return t;
}

function plainDot(a: int32[], b: int32[]): int32 {
	let t: int32 = 0;
	for (const [x, y] of Iterator.zip([a.values(), b.values()])) t += x * y;
	return t;
}

function repeated(v: int32, count: int32): int32[] {
	const out: int32[] = [];
	for (let i: int32 = 0; i < count; i++) out.push(i % 3 == 0 ? v : -v);
	return out;
}

const small: int32[] = [];
for (let i: int32 = 0; i < 3000; i++) small.push((i * 7) % 1000 - 500);
console.log(`small ${dot(small, small)}`);
console.log(`wide ${dot(repeated(40000, 3000), repeated(50000, 3000))}`);
console.log(`extremes ${plainDot([-32768], [-32768])} ${plainDot([-32768, 5], [-32767, -7])}`);
console.log(`${dot(repeated(46341, 2000), repeated(46341, 2000))}`);
