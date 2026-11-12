// @exit: 1
// @stdout: prefix 2147481600
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the sum wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: two blocks of 1024 terms of 1048575 fit int32 with 2047 to spare, so the third block's one term overflows only
// because of what the sum already holds; the fused guard counts it and the checked rerun stops there.

function total(xs: int32[]): int32 {
	let t: int32 = 0;
	for (const x of xs) t += x;
	return t;
}

function filled(n: int32): int32[] {
	const out: int32[] = [];
	for (let k: int32 = 0; k < n; k++) out.push(1048575);
	return out;
}

console.log(`prefix ${total(filled(2048))}`);
console.log(total(filled(2049)));
console.log("unreachable");
