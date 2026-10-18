// @exit: 1
// @stdout: value 9223372036854775813 not in range -32768 .. 32767
// @xfail(danger): --danger drops range checks, so the conversion wraps instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a range stop prints a uint64 past int64 as its unsigned value; C used to print it as a float (9.2233720368547758e+18).

function toInt16(v: uint64): int16 { return v as int16; }

function main(): void {
	const big: uint64 = 9223372036854775813;
	console.log(`kept=${toInt16(32767)}`);
	console.log(toInt16(big));
	console.log("unreachable");
}

main();
