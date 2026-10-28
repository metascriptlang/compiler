// @stdout: global 3|local 2|nested 2|runtime 3
// @exit: 0
// note: a recursive union holding strings is released without registering a string as a cycle candidate, for a literal string, a run-time string, at the top level, in a local and one array level deeper.
type Json = string | number | Json[];

const top: Json = [1, "a", [2]];

function run(): string {
	const inner: Json = ["x", ["y", 3]];
	const built: Json = ["p" + "q", "r".repeat(2), 4];
	const depth = (inner as Json[])[1] as Json[];
	return `local ${(inner as Json[]).length}|nested ${depth.length}|runtime ${(built as Json[]).length}`;
}

console.log(`global ${(top as Json[]).length}|${run()}`);
