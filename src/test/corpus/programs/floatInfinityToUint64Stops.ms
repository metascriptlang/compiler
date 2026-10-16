// @exit: 1
// @stdout: value Infinity not in range 0 .. 18446744073709551615
// @xfail(danger): --danger drops range checks, so the conversion is undefined in C instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: an infinite float converted to uint64 stops; before, JS threw node's own RangeError and the Raiser gave 9223372036854775807. Same on every backend.

function toU64(v: float64): uint64 { return v as uint64; }

function main(): void {
	const one: float64 = 1;
	const zero: float64 = 0;
	console.log(`kept=${toU64(18446744073709549568.0)}`);
	console.log(toU64(one / zero));
	console.log("unreachable");
}

main();
