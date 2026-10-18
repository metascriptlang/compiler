// An array's Content struct spells a by-value element by the name that element's definition carries.

import { compileToC } from "../helpers";

const strRes = "struct StrRes = match (ok: boolean) { true => { value: string }, false => { error: string } };\nfunction make(s: string): StrRes { return { ok: true, value: s }; }\nconst r = make(\"a\");\n";

function contentElement(c: string): string {
	const at = c.indexOf("__Content { int64_t cap; ");
	if (at < 0) return "";
	const from = at + "__Content { int64_t cap; ".length;
	return c.slice(from, c.indexOf(" data[]", from));
}

test "an array of a narrowed variant names the element by its emitted variant struct" {
	const result = compileToC(strRes + "if (r.ok) {\n\tconst kept = [r, r];\n\tconsole.log(kept.length);\n}");
	assert result.ok;
	const elem = contentElement(result.value);
	assert elem != "";
	assert elem.contains("_v0");
	assert result.value.contains("} " + elem + ";");
}

test "an array of a narrowed error variant names the element by its emitted variant struct" {
	const result = compileToC(strRes + "if (!r.ok) {\n\tconst kept = [r];\n\tconsole.log(kept.length);\n}");
	assert result.ok;
	const elem = contentElement(result.value);
	assert elem != "";
	assert elem.contains("_v1");
	assert result.value.contains("} " + elem + ";");
}

test "an array of a named struct names the element by its struct body" {
	const result = compileToC("struct P { x: int32; y: int32 }\nconst a: P[] = [{ x: 1, y: 2 }];\nconsole.log(a.length);");
	assert result.ok;
	const elem = contentElement(result.value);
	assert elem != "";
	assert result.value.contains("struct " + elem + " {");
}
