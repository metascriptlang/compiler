// @xfail(raiser): a float64 local initialised from an int literal truncates += 0.25 on raiser, card .inbox/compiler/2026-09-24-raiser-float-from-int-literal-truncates.md
// @stdout: for-init 0 0.25 0.5 0.75 | 3000000000
// note: the type written on a C-style for binding is the binding's type. Pre-fix the parser skipped it, so `x: float64 = 0` became int32 and `x += 0.25` never left 0 (the loop ran forever), and `i: int64` multiplied as int32.

let out = "for-init";
for (let x: float64 = 0; x < 1; x += 0.25) {
	out = out + " " + x.toString();
}
let big: int64 = 0;
for (let i: int64 = 1; i <= 3; i += 1) {
	big = i * 1000000000;
}
console.log(out + " | " + big.toString());
