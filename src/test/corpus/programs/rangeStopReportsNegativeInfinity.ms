// @exit: 1
// @stdout: value -Infinity not in range -9223372036854775808 .. 9223372036854775807
// @xfail(danger): --danger drops range checks, so the conversion wraps instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a range stop prints an infinite float as `${x}` prints it; C used to print -inf.

function toInt64(v: float64): int64 { return v as int64; }

function main(): void {
	const one: float64 = 1;
	const zero: float64 = 0;
	console.log(`kept=${toInt64(-9223372036854775808.0)}`);
	console.log(toInt64(-one / zero));
	console.log("unreachable");
}

main();
