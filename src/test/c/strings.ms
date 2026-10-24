// E2E: String Operations → C output
// Tests string lowering transforms (stringOpLower) and codegen.

import { compileToC } from "../helpers";
import { readFile } from "std/fs";
import { join } from "std/fs/path";
import { resolveRuntimeDir } from "../../utils/path";


test "E2E C: string concat" {
	const src = "function f(a: string, b: string): string { return a + b; }\nconst r = f(\"hello\", \"world\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringConcat");
}

test "E2E C: string equality" {
	const src = "function eq(a: string, b: string): boolean { return a === b; }\nconst r = eq(\"a\", \"b\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringEquals");
}

test "E2E C: string literal pool" {
	const src = "const s: string = \"hello\";\nconst x: number = 1;";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("MS_STRING_LIT");
}

test "E2E C: string length remapping" {
	const src = "function len(s: string): number { return s.length; }\nconst r = len(\"hi\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains(".len");
}

test "E2E C: string inequality" {
	const src = "function neq(a: string, b: string): boolean { return a !== b; }\nconst r = neq(\"a\", \"b\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringEquals");
}

test "E2E C: string param and return" {
	const src = "function echo(s: string): string { return s; }\nconst r = echo(\"test\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msString");
}

function matchOf(arms: int32): string {
	let body = "";
	for (let i = 0; i < arms; i++) body = body + "\"k" + i.toString() + "\" => " + i.toString() + ", ";
	return "function f(s: string): int32 { return match (s) { " + body + "_ => -1 }; }
const r = f(\"k1\");";
}

test "E2E C: a string match hashes past eight arms and is an if-chain at eight" {
	const nine = compileToC(matchOf(9));
	const eight = compileToC(matchOf(8));
	assert nine.ok && eight.ok;
	assert nine.value.contains("switch (msStringHash(");
	assert !eight.value.contains("msStringHash(");
	assert eight.value.contains("msStringEquals(");
}

// A match carries one `msStringEquals` test per arm in every function that has one, so the equality
// test is inline in the header (length, pointer, memcmp) and the hash loop is one out-of-line copy.
test "runtime string header: equality is inline, the hash is one out-of-line definition" {
	const root = resolveRuntimeDir();
	assert root != "";
	const header = readFile(join(root, "runtime/core/string.h"));
	const source = readFile(join(root, "runtime/core/string.c"));
	assert header.ok && source.ok;
	assert header.value.contains("static inline bool msStringEquals(");
	assert !header.value.contains("static inline int32_t msStringHash(");
	assert header.value.contains("int32_t msStringHash(msString s);");
	assert source.value.contains("int32_t msStringHash(msString s) {");
	assert !source.value.contains("bool msStringEquals(");
}
