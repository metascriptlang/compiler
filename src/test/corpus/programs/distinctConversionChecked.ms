// @exit: 1
// @stdout: value 200 not in range -128 .. 127
// @xfail(danger): --danger drops range checks, so the conversion wraps instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms tests pin the raiser check
// note: a conversion into a distinct type checks the value as a conversion into its base type does: an in-range value is kept (from int32, int64 and a float, which truncates), a value outside a signed base stops with a range error, and a value converted to a distinct over an unsigned base wraps to its width. Same on every backend.

type Small = distinct int8;
type Byte = distinct uint8;
type Wide = distinct int32;

function toSmall(v: int32): Small { return v as Small; }
function toWide(v: int64): Wide { return v as Wide; }
function fromFloat(v: float64): Small { return v as Small; }
function toByte(v: int32): Byte { return v as Byte; }

function main(): void {
	const kept = `${toSmall(-128) as int8},${toWide(-2147483648 as int64) as int32},${fromFloat(127.9) as int8}`;
	console.log(`in=${kept} wrap=${toByte(300) as int32},${toByte(-1) as int32}`);
	console.log(toSmall(200) as int8);
	console.log("unreachable");
}

main();
