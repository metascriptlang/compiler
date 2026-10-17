// @exit: 1
// @stdout: hot 1000000 2147483647 -2147483648
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the difference is undefined in C instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: after a million calls of the same int32 sum and difference, a result on a bound is kept and one below MIN stops.

function add(a: int32, b: int32): int32 { return a + b; }
function sub(a: int32, b: int32): int32 { return a - b; }

function main(): void {
	let s: int32 = 0;
	for (let i = 0; i < 1000000; i++) s = sub(add(s, 3), 2);
	console.log(`hot ${s} ${add(2147483646, 1)} ${sub(-2147483647, 1)}`);
	console.log(sub(-2147483648, 1));
	console.log("unreachable");
}

main();
