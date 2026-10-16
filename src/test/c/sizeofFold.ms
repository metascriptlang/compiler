// sizeof folds at compile time; a type with no computable layout defers to the C compiler.

import { compileToC } from "../helpers";
import { TargetInfo } from "../../checker/types";

const avr: TargetInfo = { ptrSize: 2, floatSize: 4, cpu: "avr", os: "bare" };

test "sizeof folds a primitive to its width" {
	const result = compileToC("const w: int32 = sizeof(int32);\nconsole.log(w);");
	assert result.ok;
	assert result.value.contains("= (int32_t)4;");
}

test "sizeof folds a struct to its padded width" {
	const result = compileToC("struct Mixed { a: char; b: int32 }\nconst w: int32 = sizeof(Mixed);\nconsole.log(w);");
	assert result.ok;
	assert result.value.contains("= (int32_t)8;");
}

test "sizeof refuses an extern class placeholder that never resolved" {
	const result = compileToC("extern class OpaqueThing;\nconst w: int32 = sizeof(OpaqueThing);\nconsole.log(w);");
	assert !result.ok;
	assert result.error.contains("'sizeof' needs a type with a known layout");
}

test "sizeof defers a struct to the C compiler on a 16-bit target" {
	const result = compileToC("struct Head { c: int8; x: int64 }\nconst w: int32 = sizeof(Head);\nconsole.log(w);", avr);
	assert result.ok;
	assert result.value.contains("sizeof(Head");
	assert !result.value.contains("= (int32_t)16;");
}

test "sizeof refuses void rather than folding it to zero" {
	const result = compileToC("const w: int32 = sizeof(void);\nconsole.log(w);");
	assert !result.ok;
	assert result.error.contains("'sizeof' needs a type with a known layout");
}

test "a Result stores its discriminant once, in its tag, and sizeof counts it once" {
	const result = compileToC("struct Key { bytes: uint8[32] }\nstruct Failure { code: uint64 }\nconst w: int32 = sizeof(Result<Key, Failure>);\nconsole.log(w);");
	assert result.ok;
	assert result.value.contains("= (int32_t)40;");
	assert !result.value.contains("MS_BOOL ok;");
}

test "a union of named structs keeps their discriminator field, which each struct owns" {
	const result = compileToC("struct Hit { ok: true; at: uint8 }\nstruct Miss { ok: false; why: string }\ntype Probe = Hit | Miss;\nconst w: int32 = sizeof(Probe);\nconsole.log(w);");
	assert result.ok;
	assert result.value.contains("= (int32_t)32;");
	assert result.value.contains("MS_BOOL ok;");
}

test "an arm of a match union stores a field of one boolean value nowhere and reads it as that value" {
	const result = compileToC("type Lone = match (ok: boolean) { true => { n: int32 }, false => { m: int32 } };\nconst a: Lone = { ok: true, n: 3 };\nconsole.log(a.ok);");
	assert result.ok;
	assert !result.value.contains("MS_BOOL ok;");
	assert result.value.contains("typedef struct {\n  int32_t n;\n} Lone");
}

test "an object with a field of one boolean value stores it beside an object with a boolean field" {
	const result = compileToC("type Lone = { ok: true; n: int32 };\ntype Both = { ok: boolean; n: int32 };\nconst a: Lone = { ok: true, n: 3 };\nconst b: Both = { ok: false, n: 4 };\nconsole.log(a.n, b.ok);");
	assert result.ok;
	assert result.value.contains("{\n  MS_BOOL ok;\n  int32_t n;\n};");
	assert !result.value.contains("{\n  int32_t n;\n};");
}

test "a union asserts its checker size to C on 64-bit and 32-bit targets" {
	const source = "type Word = match (ok: boolean) { true => { text: string }, false => { code: int32 } };\nconst w: int32 = sizeof(Word);\nconsole.log(w);";
	const host = compileToC(source);
	assert host.ok;
	assert host.value.contains("== 24, \"struct Word");
	const arm: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "arm", os: "linux" };
	const onArm = compileToC(source, arm);
	assert onArm.ok;
	assert onArm.value.contains("== 24, \"struct Word");
	const i386: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "i386", os: "linux" };
	const onI386 = compileToC(source, i386);
	assert onI386.ok;
	assert onI386.value.contains("== 16, \"struct Word");
}

test "a union of string literals folds sizeof to the string that holds it" {
	const result = compileToC("type Align = \"auto\" | \"center\";\nstruct Holder { a: Align | null }\nconst w: int32 = sizeof(Align);\nconst h: int32 = sizeof(Holder);\nconsole.log(w, h);");
	assert result.ok;
	assert result.value.contains("= (int32_t)16;");
	assert result.value.contains("= (int32_t)24;");
}
