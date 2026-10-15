// @exit: 1
// @stdout: value 1152921573326323713 not in range -2147483648 .. 2147483647
// @xfail(danger): --danger drops range checks, so the conversion wraps instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a range stop prints an int64 past 2^53 exactly; C used to print it rounded through a double (1152921573326323712), JS and the Raiser printed it exact.

function toInt32(v: int64): int32 { return v as int32; }

function main(): void {
	const big: int64 = 1152921573326323713;
	console.log(`kept=${toInt32(-2147483648)}`);
	console.log(toInt32(big));
	console.log("unreachable");
}

main();
