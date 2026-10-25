// @stdout: returned solid dots none
// @stdout: elsed a,none,b
// @stdout: either none,none,c
// note: `===` and `!==` against a literal narrow a nullable literal union as they narrow the union without null. The branch where the value equals the literal drops null; the branch where it differs keeps null. Before, the comparison was already lowered to the nullable equality routine when the flow read it, so nothing narrowed and the return or argument was refused.
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
console.log("returned " + returned("solid") + " " + returned("dotted") + " " + returned(null));
console.log("elsed " + show(elsed("a")) + "," + show(elsed("c")) + "," + show(elsed("b")));
console.log("either " + show(either("a")) + "," + show(either("b")) + "," + show(either("c")));
