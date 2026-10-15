// @exit: 1
// @stdout: value 9223372036854775808 not in range -9223372036854775808 .. 9223372036854775807
// @xfail(danger): --danger drops range checks, so the conversion wraps instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a uint64 converted to int64 keeps a value up to 2^63-1 and stops with a range error past it; int64Bits gives the bit pattern and a conversion to uint32 wraps. Same on every backend.

function toInt64(v: uint64): int64 { return v as int64; }
function toWord(v: uint64): uint32 { return v as uint32; }

function main(): void {
	const top: uint64 = 9223372036854775807;
	const past: uint64 = 9223372036854775808;
	console.log(`kept=${toInt64(top)} bits=${int64Bits(past)},${int64Bits(18446744073709551615)} wrap=${toWord(9223372036854775813)}`);
	console.log(toInt64(past));
	console.log("unreachable");
}

main();
