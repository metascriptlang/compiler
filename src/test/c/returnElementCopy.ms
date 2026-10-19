import { compileToC } from "../helpers";

function copiesIn(code: string, fn: string): int32 {
	let start = -1;
	for (const line of code.split("\n")) {
		if (line.endsWith(" {") && line.indexOf(" " + fn + "__") >= 0) { start = code.indexOf(line + "\n"); break; }
	}
	if (start < 0) return -1;
	return (code.slice(start, code.indexOf("\n}", start)).split("msStringCopy(").length - 1) as int32;
}

const SRC = `
class Inner { items: string[] = []; }
class Outer { b: Inner = new Inner(); }
function get(a: string[], i: number): string { return a[i]; }
function nested(o: Outer, i: number): string { return o.b.items[i]; }
function guarded(a: string[], i: number, m: number): string {
	if (m == 0) return a[i];
	return a[i + 1];
}
console.log(get(["a"], 0) + nested(new Outer(), 0) + guarded(["a"], 0, 0));
`;

test "returnElementCopy: a returned string element is copied once, into the result" {
	const result = compileToC(SRC);
	assert result.ok, result.error;
	assert copiesIn(result.value, "get") == 1;
	assert copiesIn(result.value, "nested") == 1;
	assert copiesIn(result.value, "guarded") == 2;
}
