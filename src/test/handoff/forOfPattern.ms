// Checker — an array pattern in a for-of destructures a tuple or array element; over a Map it takes the entries

import { strictErrorCount, hasError } from "./helpers";

test "an array pattern over a Map binds the key and the value types" {
	const pre = "function f(m: Map<string, int32>): void {\n\tfor (const [k, v] of m) {\n";
	assert strictErrorCount(pre + "\t\tconst key: string = k;\n\t\tconst value: int32 = v;\n\t}\n}") == 0;
	assert strictErrorCount(pre + "\t\tconst wrong: string = v;\n\t}\n}") > 0;
}

test "an array pattern over a Set or a scalar array is refused" {
	assert hasError("function f(s: Set<int32>): void { for (const [a, b] of s) {} }", "an array pattern needs each element to be a tuple or an array");
	assert hasError("function f(xs: int32[]): void { for (const [a] of xs) {} }", "an array pattern needs each element to be a tuple or an array");
}

test "a tuple or array element keeps its destructuring" {
	assert strictErrorCount("type Row = [string, int32];\nfunction f(rows: Row[], grid: int32[][]): void {\n\tfor (const [k, v] of rows) {}\n\tfor (const [p, q] of grid) {}\n}") == 0;
}
