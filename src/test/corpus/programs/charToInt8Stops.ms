// @exit: 1
// @stdout: value 200 not in range -128 .. 127
// @xfail(danger): --danger drops range checks, so the conversion wraps in C instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/codegen/raiser/eval.ms tests pin the raiser check
// note: a char past 127 converted to int8 stops, because int8 cannot hold it; int16 and uint8 hold every char.

function toI8(c: char): int8 { return c as int8; }

function main(): void {
	const bytes: int32[] = [127, 200];
	const high = bytes[1] as char;
	console.log(`kept=${toI8(bytes[0] as char)},${high as int16},${high as uint8}`);
	console.log(toI8(high));
	console.log("unreachable");
}

main();
