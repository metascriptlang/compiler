// @exit: 1
// @stdout: value 256 not in range 0 .. 255
// @xfail(danger): --danger drops range checks, so the conversion is undefined in C instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a float32 converted to uint8 through a generic `as T` keeps 255.5 as 255 and stops at 256. Same on every backend.

function conv<T>(v: float32): T { return v as T; }

function main(): void {
	const top: float32 = 255.5;
	const past: float32 = 256.0;
	console.log(`kept=${conv<uint8>(top)}`);
	console.log(conv<uint8>(past));
	console.log("unreachable");
}

main();
