// @stdout: modconst r=11-1-2.5-7
// Module-scope const with a ternary (or match) initializer: the lowering leaves
// a NullLiteral placeholder on the decl, and the C global-init path used to
// emit `x = MS_NIL;` for numeric/bool targets — a compile error (void* into
// int32_t). The struct flavor was already handled via `(T){0}`; this pins the
// numeric/bool cell of the same matrix.

let c = "ab".length > 1;
const a: int32 = c ? 11 : 22;
const b: boolean = c ? true : false;
const bi: int32 = b ? 1 : 0;
const f: float64 = c ? 2.5 : 3.5;
const m: int32 = match (a) {
	11 => 7,
	_ => 9,
};

console.log("modconst r=" + a.toString() + "-" + bi.toString() + "-" + f.toString() + "-" + m.toString());
