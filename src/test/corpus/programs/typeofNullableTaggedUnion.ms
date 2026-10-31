// @stdout: number number string object|number number string object|number string object|number number object
function kind(v: float32 | int32 | string | null): string { return typeof v; }
function kindWide(v: int64 | float64 | string | null): string { return typeof v; }
function kindScalar(v: int32 | string | null): string { return typeof v; }
function kindNumbers(v: int32 | float64 | null): string { return typeof v; }

const f: float32 = 2.5;
const i: int32 = 3;
const w: int64 = 9;
const d: float64 = 1.5;
console.log([
	[kind(f), kind(i), kind("50%"), kind(null)].join(" "),
	[kindWide(w), kindWide(d), kindWide("x"), kindWide(null)].join(" "),
	[kindScalar(i), kindScalar("a"), kindScalar(null)].join(" "),
	[kindNumbers(i), kindNumbers(d), kindNumbers(null)].join(" ")
].join("|"));
