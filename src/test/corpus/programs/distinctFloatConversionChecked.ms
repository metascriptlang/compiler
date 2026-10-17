// @exit: 1
// @stdout: value -1.5 not in range 0 .. 255
// @xfail(danger): --danger drops range checks, so the conversion is undefined instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a float converted into a distinct over an unsigned integer is checked as a float converted into that integer is: a value inside the range truncates, one outside it stops with a range error instead of an undefined conversion. Same on every backend.

type Byte = distinct uint8;

function toByte(v: float64): Byte { return v as Byte; }

function main(): void {
	console.log(`in=${toByte(255.9) as int32},${toByte(0.5) as int32}`);
	console.log(toByte(-1.5) as int32);
	console.log("unreachable");
}

main();
