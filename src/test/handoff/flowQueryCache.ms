import { strictErrorCount } from "./helpers";

const PRELUDE = "enum K { Num, Str }\ntype D = match (kind: K) { K.Num => { a: int64 }, K.Str => { text: string } };\n";

test "flowQueryCache: references sharing a flow node narrow independently" {
	const cases = [
		{ name: "a sibling reference is not narrowed by the other's condition", source: PRELUDE + "function f(a: D, b: D): string {\n\tif (a.kind == K.Str) { return a.text + b.text; }\n\treturn \"\";\n}\n", expected: -1 },
		{ name: "the sibling read first does not hand its type to the narrowed one", source: PRELUDE + "function f(a: D, b: D): string {\n\tif (a.kind == K.Str) { const n = b.kind; return a.text; }\n\treturn \"\";\n}\n", expected: 0 },
		{ name: "both references narrowed by their own conditions", source: PRELUDE + "function f(a: D, b: D): string {\n\tif (a.kind == K.Str && b.kind == K.Str) { return a.text + b.text; }\n\treturn \"\";\n}\n", expected: 0 },
		{ name: "a loop label serves each reference its own type", source: PRELUDE + "function f(xs: D[], a: D, b: D): string {\n\tlet out = \"\";\n\tfor (const x of xs) {\n\t\tif (a.kind == K.Str) { out = out + a.text; out = out + b.text; }\n\t}\n\treturn out;\n}\n", expected: -1 },
		{ name: "a write to one local in the loop leaves the other narrowed", source: PRELUDE + "function f(xs: D[], first: D): string {\n\tlet d: D = first;\n\tlet e: D = first;\n\tlet out = \"\";\n\tfor (const x of xs) {\n\t\tif (e.kind == K.Str) { d = x; out = out + e.text; }\n\t}\n\treturn out;\n}\n", expected: 0 },
		{ name: "a write to a local in the loop drops its own narrowing", source: PRELUDE + "function f(xs: D[], first: D): string {\n\tlet d: D = first;\n\tlet out = \"\";\n\tfor (const x of xs) {\n\t\tif (d.kind == K.Str) { d = x; out = out + d.text; }\n\t}\n\treturn out;\n}\n", expected: -1 },
		{ name: "a write on the back edge drops the narrowing at the loop head for that local only", source: PRELUDE + "function f(xs: D[], first: D): string {\n\tlet d: D = first;\n\tlet e: D = first;\n\tlet out = \"\";\n\tif (e.kind == K.Str && d.kind == K.Str) {\n\t\tfor (const x of xs) { out = out + e.text; out = out + d.text; d = x; }\n\t}\n\treturn out;\n}\n", expected: -1 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}
