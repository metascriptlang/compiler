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

test "an object converted into an arm is rebuilt by a routine, not by the emitter" {
	const result = compileToC(pair + "const o: { ok: true; value: string } = { ok: true, value: \"x\" };\nfunction take(x: Pair): boolean { return x.ok; }\nconsole.log(take(o));");
	assert result.ok;
	assert result.value.contains("msArmConv_");
	assert !result.value.contains("_arm1_");
}

test "an arm that holds only its discriminator is built from the object too" {
	const result = compileToC("type Flag = match (ok: boolean) { true => {}, false => { error: string } };\nconst o: { ok: true } = { ok: true };\nconst f: Flag = o;\nconsole.log(f.ok);");
	assert result.ok;
	assert result.value.contains("msArmConv_");
	assert !result.value.contains("_arm1_");
}

test "an object that is already the arm's own struct is not rebuilt" {
	const result = compileToC(pair + "function make(good: boolean): Pair { return good ? { ok: true, value: \"y\" } : { ok: false, error: \"n\" }; }\nconsole.log(make(true).ok);");
	assert result.ok;
	assert !result.value.contains("msArmConv_");
}

test "an enum discriminator read passes as a call argument on a union of objects" {
	const result = compileToC("enum Q { Open, Shut }\ntype G = { kind: Q.Open; n: int32 } | { kind: Q.Shut; why: string };\nfunction name(q: Q): int32 { return q == Q.Open ? 1 : 2; }\nconst gs: G[] = [{ kind: Q.Open, n: 1 }, { kind: Q.Shut, why: \"w\" }];\nconsole.log(name(gs[1].kind));");
	assert result.ok;
	assert !result.value.contains("*(msArrayAccess");
}
