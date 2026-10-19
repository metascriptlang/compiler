// @exit: 1
// @stdout: value 18446744073709551613 not in range -5 .. 1
// @xfail(danger): --danger drops the range check, so the conversion keeps the low bits instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; the engine test in src/codegen/raiser/eval.ms pins the raiser check
// note: a uint64 at or past 2^63 converted into an enum stops and reports the unsigned value, even when the enum has a negative member; the Raiser read it as a negative int64, printed that and let it into an enum whose range held it.

enum Kind {
	A,
	B,
	C,
}

enum Signed {
	Neg = -5,
	Zero = 0,
	One = 1,
}

function raw(v: uint64): uint64 { return v; }

console.log(`in ${(raw(1) as Kind) as int32} ${(raw(0) as Signed) as int32}`);
console.log(`past ${(raw(18446744073709551613) as Signed) as int32}`);
console.log("unreachable");
