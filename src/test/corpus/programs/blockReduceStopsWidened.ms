// @exit: 1
// @stdout: fits 32766
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the int16 sum wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: an int16 sum of int8 elements stops at the element that takes it past 32767.

function total(xs: int8[]): int16 {
	let s: int16 = 0;
	for (const x of xs) s += x;
	return s;
}

function main(): void {
	const xs: int8[] = [];
	for (let i = 0; i < 258; i++) xs.push(127 as int8);
	console.log(`fits ${total(xs)}`);
	for (let i = 0; i < 5000; i++) xs.push(127 as int8);
	console.log(total(xs));
	console.log("unreachable");
}

main();
