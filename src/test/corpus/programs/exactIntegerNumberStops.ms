// A const number converted from an int64 outside int32 stops at its narrowing with the number's own text.
//
// @exit: 1
// @stdout: value 3000000000 not in range -2147483648 .. 2147483647
// @xfail(danger): --danger drops the range check on C, so the conversion wraps instead of stopping

function narrowed(v: int64): int32 {
	const k: number = v as number;
	return k as int32;
}

console.log(narrowed(3000000000));
