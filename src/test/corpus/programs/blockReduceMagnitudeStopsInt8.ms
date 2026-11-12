// @exit: 1
// @stdout: prefix 120
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the int8 sum wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: ten int8 terms of 12 (bit length 4) fit and the eleventh passes 127, so the fused guard refuses the
// eleven-term block and its checked rerun stops there; a bound one bit lower would take the block and wrap.

function total(xs: int8[]): int8 {
	let t: int8 = 0;
	for (const x of xs) t += x;
	return t;
}

function filled(n: int32): int8[] {
	const out: int8[] = [];
	for (let k: int32 = 0; k < n; k++) out.push(12 as int8);
	return out;
}

console.log(`prefix ${total(filled(10))}`);
console.log(total(filled(11)));
console.log("unreachable");
