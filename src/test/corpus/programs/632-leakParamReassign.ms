// @maxrss: 20
// @stdout: leak-param-reassign r=
// Params are borrowed slots the DRC injector never destroys; assigning an
// owned value into one leaked it (~16 B/iter, 82 MB at 5M calls) until
// paramReassignLower redirected assigned params through owned shadow locals.
// Tail recursion hit the same hole through tailCallLower's loop state.

function once(s: string): int32 {
	s = s + "x";
	return s.length;
}

function tailrec(n: int32, s: string): string {
	if (n <= 0) return s;
	return tailrec(n - 1, s.slice(0, 1) + "x");
}

let total: int64 = 0;
for (let i = 0; i < 3000000; i += 1) {
	total += once("h");
}
const t = tailrec(3000000, "h");
console.log("leak-param-reassign r=" + total.toString() + "-" + t.length.toString());
