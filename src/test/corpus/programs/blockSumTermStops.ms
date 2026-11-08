// A checked reduction whose term overflows at one element stops there, not at the end of its block.
//
// @exit: 1
// @stdout: start
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the product wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check

function* upTo(limit: int32): Iterator<int32> {
	for (let i: int32 = 0; i < limit; i++) yield i;
}

function scaled(n: int32): int32 {
	let total: int32 = 0;
	for (const x of upTo(n)) total += (x * 100000) & 3;
	return total;
}

console.log("start");
console.log(scaled(30000));
