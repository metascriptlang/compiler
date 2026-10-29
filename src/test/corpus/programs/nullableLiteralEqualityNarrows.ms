// @stdout: returned solid dots none
// @stdout: elsed a,none,b
// @stdout: either none,none,c
// @stdout: count other three none
// @stdout: below 1,none,none
// @stdout: sameCount true,false,false,true
// @stdout: sameLetter true,false,false,true
// @stdout: sameWidth true,false,false,true
// note: `===` and `!==` against a literal narrow a nullable literal union as they narrow the union without null. The branch where the value equals the literal drops null; the branch where it differs keeps null. Before, the comparison was already lowered to the nullable equality routine when the flow read it, so nothing narrowed and the return or argument was refused. A number literal union is carried as its number, so two of them, once past null, compare as numbers: C used to compare them as tagged unions and failed to compile.
type Style = "solid" | "wavy" | "dotted";
function draw(line: "solid" | "wavy" | null): string { return line === null ? "none" : line; }
function returned(own: Style | null): string {
	if (own === "dotted") return "dots";
	return draw(own);
}
function show(v: string | null): string { return v === null ? "none" : v; }
function elsed(x: "a" | "b" | "c" | null): "a" | "b" | null {
	if (x !== "c") { return x; } else { return null; }
}
function either(x: "a" | "b" | "c" | null): "c" | null {
	if (x === "a" || x === "b") return null;
	return x;
}
function count(own: 1 | 2 | 3 | null): string {
	if (own === 3) return "three";
	return own === null ? "none" : "other";
}
function below(x: 1 | 2 | 3 | null): 1 | 2 | null {
	if (x !== 3) { return x; } else { return null; }
}
function digit(v: 1 | 2 | null): string { return v === null ? "none" : v === 1 ? "1" : "2"; }
function sameCount(a: 1 | 2 | 3 | null, b: 1 | 2 | 3 | null): boolean { return a === b; }
function sameLetter(a: "a" | "b" | null, b: "a" | "b" | null): boolean { return a === b; }
interface Pen { width: 0.5 | 1.5 | null; }
function sameWidth(p: Pen, q: Pen): boolean { return p.width === q.width; }
console.log("returned " + returned("solid") + " " + returned("dotted") + " " + returned(null));
console.log("elsed " + show(elsed("a")) + "," + show(elsed("c")) + "," + show(elsed("b")));
console.log("either " + show(either("a")) + "," + show(either("b")) + "," + show(either("c")));
console.log("count " + count(1) + " " + count(3) + " " + count(null));
console.log("below " + digit(below(1)) + "," + digit(below(3)) + "," + digit(below(null)));
console.log(`sameCount ${sameCount(1, 1)},${sameCount(1, 2)},${sameCount(1, null)},${sameCount(null, null)}`);
console.log(`sameLetter ${sameLetter("a", "a")},${sameLetter("a", "b")},${sameLetter(null, "b")},${sameLetter(null, null)}`);
console.log(`sameWidth ${sameWidth({ width: 0.5 }, { width: 0.5 })},${sameWidth({ width: 0.5 }, { width: 1.5 })},${sameWidth({ width: null }, { width: 1.5 })},${sameWidth({ width: null }, { width: null })}`);
