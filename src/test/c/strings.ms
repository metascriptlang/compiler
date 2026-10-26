// E2E: String Operations → C output
// Tests string lowering transforms (stringOpLower) and codegen.

import { compileToC, compileProjectToCWithStd } from "../helpers";


test "E2E C: string concat" {
	const src = "function f(a: string, b: string): string { return a + b; }\nconst r = f(\"hello\", \"world\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringConcat");
}

test "E2E C: string equality" {
	const src = "function eq(a: string, b: string): boolean { return a === b; }\nconst r = eq(\"a\", \"b\");";
	const c = compileProjectToCWithStd([{ entryPath: "test/e2e.ms", entrySource: src }], "test/e2e.ms", true);
	assert !c.startsWith("ERROR"), c;
	assert c.contains("static inline MS_BOOL msStringEquals"), c;
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
	const c = compileProjectToCWithStd([{ entryPath: "test/e2e.ms", entrySource: src }], "test/e2e.ms", true);
	assert !c.startsWith("ERROR"), c;
	assert c.contains("static inline MS_BOOL msStringEquals"), c;
}

test "E2E C: string param and return" {
	const src = "function echo(s: string): string { return s; }\nconst r = echo(\"test\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msString");
}
