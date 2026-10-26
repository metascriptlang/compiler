// @xfail(raiser): the raiser std has no string.stripInPlace, so the program stops at the checker
// @stdout: ""0 ""0 ""0 "a"1 "a"1 "x y"3 "héllo"5 ""0 "ab"2 "ab"2
// @stdout: 2 "lit" "shared" " shared "
// @skip-js: strings are immutable on JS, so stripInPlace throws there by design
const cases = ["", " ", "   ", "a", " a ", "\t\n\v\f\r x y \r\n", "  héllo  ", "\v", "ab  ", "  ab"];
const parts: string[] = [];
for (const c of cases) {
	let w = c + "";
	w.stripInPlace();
	parts.push(JSON.stringify(w) + w.length);
}
console.log(parts.join(" "));
let nbsp = "x\u00a0";
nbsp.stripInPlace();
let lit = "  lit  ";
lit.stripInPlace();
let shared = " shared ";
const keep = shared;
shared.stripInPlace();
console.log(nbsp.length, JSON.stringify(lit), JSON.stringify(shared), JSON.stringify(keep));
