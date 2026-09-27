// @stdout: const-fold 4 -3 6 1 -1 4 3.5
// note: every operand is a literal, so the compiler's constant folding answers each value before codegen. Pre-fix it folded in doubles whatever the checked type: `9 / 2` into an int32 was 4.5 on JS, and `(7 / 2) * 2` was 7 on every backend.

function quotient(): int32 {
	return -7 / 2;
}

const t: int32 = 9 / 2;
const nested: int32 = (7 / 2) * 2;
const rem: int32 = 7 % 3;
const negRem: int32 = -7 % 2;
const wide: int64 = 9 / 2;
const f: float64 = 7.0 / 2;
console.log(`const-fold ${t} ${quotient()} ${nested} ${rem} ${negRem} ${wide} ${f}`);
