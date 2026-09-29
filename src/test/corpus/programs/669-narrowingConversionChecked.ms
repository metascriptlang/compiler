// @exit: 1
// @stdout: value 200 not in range -128 .. 127
// @skip-js: node reports the thrown range error with its own stack trace and parity compares merged output (sibling of 647); fixedbugs bug634 pins the JS check
// @xfail(danger): --danger drops range checks, so the conversion wraps instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a conversion to a narrower signed integer keeps an in-range value (from int32, int64, uint8 and a float, which truncates) and stops with a range error on the first value outside the target's range; a conversion to an unsigned type wraps. Same on every backend.

function toInt8(v: int32): int8 { return v as int8; }
function toInt32(v: int64): int32 { return v as int32; }
function fromUnsigned(v: uint8): int8 { return v as int8; }
function fromFloat(v: float64): int8 { return v as int8; }
function toByte(v: int32): uint8 { return v as uint8; }

function main(): void {
	const kept = `${toInt8(-128)},${toInt32(-2147483648 as int64)},${fromUnsigned(127)},${fromFloat(127.9)}`;
	console.log(`in=${kept} wrap=${toByte(300)}`);
	console.log(toInt8(200));
	console.log("unreachable");
}

main();
