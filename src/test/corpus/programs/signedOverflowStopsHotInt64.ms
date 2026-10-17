// @exit: 1
// @stdout: hot 1000000 9223372036854775807 -9223372036854775808
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the sum is undefined in C instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: after a million calls of the same int64 sum and difference, a result on a bound is kept and one above MAX stops.

function add(a: int64, b: int64): int64 { return a + b; }
function sub(a: int64, b: int64): int64 { return a - b; }

function main(): void {
	let s: int64 = 0;
	for (let i = 0; i < 1000000; i++) s = sub(add(s, 3), 2);
	console.log(`hot ${s} ${add(9223372036854775806, 1)} ${sub(-9223372036854775807, 1)}`);
	console.log(add(9223372036854775807, 1));
	console.log("unreachable");
}

main();
