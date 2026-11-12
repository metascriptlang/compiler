// @exit: 1
// @stdout: prefix -30000
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the int16 difference wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: an int16 `-=` of ten terms of 3000 (bit length 12) fits and the eleventh passes -32768, so the fused guard
// refuses the eleven-term block and its checked rerun stops there; a bound one bit lower would take the block and wrap.

function drain(xs: int16[]): int16 {
	let t: int16 = 0;
	for (const x of xs) t -= x;
	return t;
}

function filled(n: int32): int16[] {
	const out: int16[] = [];
	for (let k: int32 = 0; k < n; k++) out.push(3000 as int16);
	return out;
}

console.log(`prefix ${drain(filled(10))}`);
console.log(drain(filled(11)));
console.log("unreachable");
