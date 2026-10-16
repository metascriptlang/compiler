// @exit: 1
// @stdout: value 128.9 not in range -128 .. 127
// @xfail(danger): --danger drops range checks, so the conversion wraps instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a range stop prints a float as `${x}` prints it; C used to print 128.90000000000001.

function toInt8(v: float64): int8 { return v as int8; }

function main(): void {
	console.log(`kept=${toInt8(127.9)}`);
	console.log(toInt8(128.9));
	console.log("unreachable");
}

main();
