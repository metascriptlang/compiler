// A one-value field is stored by an object, whose reference is read as the wide type, and left to the union tag by an arm.

import { compileToC } from "../helpers";

const pair = "type Pair = match (ok: boolean) { true => { value: string }, false => { error: string } };\n";

test "an object with a boolean-literal field stores it" {
	const result = compileToC("const o: { ok: true; value: string } = { ok: true, value: \"x\" };\nconsole.log(o.ok);");
	assert result.ok;
	assert result.value.contains("  MS_BOOL ok;\n  msString value;\n};");
}

test "an arm of a boolean match union stores only its payload" {
	const result = compileToC(pair + "const p: Pair = { ok: true, value: \"y\" };\nconsole.log(p.ok);");
	assert result.ok;
	assert result.value.contains("typedef struct {\n  msString value;\n} Pair");
	assert !result.value.contains("MS_BOOL ok;");
}

test "an object and an arm of one shape get their own C structs" {
	const result = compileToC(pair + "const o: { ok: true; value: string } = { ok: true, value: \"x\" };\nconst p: Pair = { ok: true, value: \"y\" };\nconsole.log(o.ok, p.ok);");
	assert result.ok;
	assert result.value.contains("  MS_BOOL ok;\n  msString value;\n};");
	assert result.value.contains("typedef struct {\n  msString value;\n} Pair");
}

test "an arm of an enum match union stores no enum discriminator beside the tag" {
	const result = compileToC("enum K { A, B }\ntype S = match (kind: K) { K.A => { r: string }, K.B => { n: int32 } };\nconst s: S = { kind: K.A, r: \"x\" };\nconsole.log(s.kind == K.A);");
	assert result.ok;
	assert result.value.contains("typedef struct {\n  msString r;\n} S");
	assert result.value.contains("typedef struct {\n  int32_t n;\n} S");
}

test "an object converted into an arm fills the arm by its stored fields" {
	const result = compileToC(pair + "const o: { ok: true; value: string } = { ok: true, value: \"x\" };\nfunction take(x: Pair): boolean { return x.ok; }\nconsole.log(take(o));");
	assert result.ok;
	assert result.value.contains("{ .value = ");
}
