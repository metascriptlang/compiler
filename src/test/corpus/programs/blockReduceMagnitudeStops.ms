// @exit: 1
// @stdout: prefix 2147483136
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the sum wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: 512 terms of 4194303 (bit length 22) fit int32 and the 513th overflows, so the fused guard refuses the
// 513-term block and its checked rerun stops there; a bound one bit lower would take the block and wrap.

function total(xs: int32[]): int32 {
	let t: int32 = 0;
	for (let i: int32 = 0; i < xs.length; i++) t += xs[i];
	return t;
}

function filled(n: int32): int32[] {
	const out: int32[] = [];
	for (let k: int32 = 0; k < n; k++) out.push(4194303);
	return out;
}

console.log(`prefix ${total(filled(512))}`);
console.log(total(filled(513)));
console.log("unreachable");
