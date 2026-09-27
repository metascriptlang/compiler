import { compileToJS } from "../helpers";

test "checked reads: JavaScript iteration raises construct Error objects" {
	const cases = [
		{ source: "const xs: string[] = [\"a\", \"b\"]; for (const x of xs) { xs.pop(); }", raised: "throw new Error(\"the length of the array changed while iterating over it\")" },
		{ source: "let text = \"ab\"; for (const ch of text) { text = text + \"c\"; }", raised: "throw new Error(\"the length of the string changed while iterating over it\")" },
	];
	for (const item of cases) {
		const js = compileToJS(item.source);
		assert js.ok, js.error;
		assert js.value.contains(item.raised), item.source;
	}
}

test "checked reads: JavaScript variant errors retain the discriminant identity" {
	for (const field of ["kind", "tag"]) {
		const source = "enum K { Num, Str } type Data = match (" + field + ": K) { K.Num => { value: float64 }, K.Str => { text: string }, }; class Box { data: Data = { " + field + ": K.Str, text: \"hello\" }; } function replace(box: Box): void { box.data = { " + field + ": K.Num, value: 1.5 }; } function read(box: Box): string { if (box.data." + field + " == K.Str) { replace(box); return box.data.text; } return \"\"; }";
		const js = compileToJS(source);
		assert js.ok, js.error;
		assert js.value.contains("using '" + field + " = \", K_toString"), field;
	}
}
