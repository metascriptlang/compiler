// @exit: 1
// @stdout: prefix 2143289344
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the difference wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a keys() `-=` of terms -4194304, whose magnitude bound is [-2^22, 2^22 - 1], fits for 511 terms and passes
// int32 at the 512th, so the sticky block refuses the 512-term block and its checked rerun stops there; a bound one
// bit lower would take the block and wrap.

function drain(xs: int32[]): int32 {
	let t: int32 = 0;
	for (const k of xs.keys()) t -= xs[k];
	return t;
}

function filled(n: int32): int32[] {
	const out: int32[] = [];
	for (let k: int32 = 0; k < n; k++) out.push(-4194304);
	return out;
}

console.log(`prefix ${drain(filled(511))}`);
console.log(drain(filled(512)));
console.log("unreachable");
