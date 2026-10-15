// @exit: 1
// @stdout: value -1.5 not in range 0 .. 255
// @xfail(danger): --danger drops range checks, so the conversion is undefined in C instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a float converted to an unsigned type truncates toward zero and stops when the result is below 0; -0.9 truncates to 0 and is kept. Same on every backend.

function toByte(v: float64): uint8 { return v as uint8; }
function toHalf(v: float64): uint16 { return v as uint16; }

function main(): void {
	console.log(`kept=${toByte(-0.9)},${toHalf(-0.5)}`);
	console.log(toByte(-1.5));
	console.log("unreachable");
}

main();
