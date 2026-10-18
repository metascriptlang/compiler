// @exit: 1
// @stdout: value 18446744073709552000 not in range 0 .. 18446744073709551615
// @xfail(danger): --danger drops range checks, so the conversion is undefined in C instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: 2^64 as a float converted to uint64 stops; the largest float below it is kept exactly. Same on every backend.

function toU64(v: float64): uint64 { return v as uint64; }

function main(): void {
	const below: float64 = 18446744073709549568.0;
	const past: float64 = 18446744073709551616.0;
	console.log(`kept=${toU64(below)}`);
	console.log(toU64(past));
	console.log("unreachable");
}

main();
