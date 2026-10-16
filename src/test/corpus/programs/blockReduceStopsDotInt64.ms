// @exit: 1
// @stdout: dot 2000 1999000
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the product wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: an int64 dot product stops at the element whose product leaves int64, in the second block of 1024.

function dot(a: int64[], b: int64[]): int64 {
	let s: int64 = 0;
	for (let k = 0; k < a.length; k++) s += a[k] * b[k];
	return s;
}

function main(): void {
	const a: int64[] = [];
	const b: int64[] = [];
	for (let i = 0; i < 2000; i++) {
		a.push(i as int64);
		b.push(1 as int64);
	}
	console.log(`dot ${a.length} ${dot(a, b)}`);
	a[1500] = 3037000500;
	b[1500] = 3037000500;
	console.log(dot(a, b));
	console.log("unreachable");
}

main();
