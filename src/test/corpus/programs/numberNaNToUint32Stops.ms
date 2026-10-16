// @exit: 1
// @stdout: value NaN not in range 0 .. 4294967295
// @xfail(danger): --danger drops range checks, so the conversion is undefined in C instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: NaN converted to an unsigned type stops; before, C debug panicked in UBSan and JS and the Raiser gave 0. Same on every backend.

function toWord(v: number): uint32 { return v as uint32; }

function main(): void {
	const zero: number = 0;
	console.log(`kept=${toWord(4294967295.5)}`);
	console.log(toWord(zero / zero));
	console.log("unreachable");
}

main();
