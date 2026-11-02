// E2E: String Operations → C output
// Tests string lowering transforms (stringOpLower) and codegen.

import { compileToC, compileProjectToCWithStd } from "../helpers";


test "E2E C: string concat" {
	const src = "function f(a: string, b: string): string { return a + b; }\nconst r = f(\"hello\", \"world\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringConcat");
}

test "E2E C: string === calls the std string == routine" {
	const src = "function eq(a: string, b: string): boolean { return a === b; }\nconst r = eq(\"a\", \"b\");";
	const c = compileProjectToCWithStd([{ entryPath: "test/e2e.ms", entrySource: src }], "test/e2e.ms");
	assert !c.startsWith("ERROR"), c;
	assert c.contains("return eqeq___") && c.contains("ZstdZcoreZstringZindexOcms_u0(a_p0, b_p1);"), c;
}

test "E2E C: a string element stored from another element is copied into the destination slot" {
	const src = "export function put(x: string[], y: string[], i: int32): void { x[i] = y[i]; }";
	const c = compileToC(src);
	assert c.ok;
	const body = c.value.slice(c.value.indexOf("int32_t i_p2) {"), c.value.length);
	assert body.contains("msStringCopy((&((*x_p0)[i_p2])), (*y_p1)[i_p2])"), body;
}

test "E2E C: a string field stored from another field is copied into the destination field" {
	const src = "export class P { a: string = \"x\"; b: string = \"y\"; }\nexport function put(p: P): void { p.b = p.a; }";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msStringCopy((&((*p_p0).b)), (*p_p0).a)"), c.value;
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

test "E2E C: string !== negates the std string == routine" {
	const src = "function neq(a: string, b: string): boolean { return a !== b; }\nconst r = neq(\"a\", \"b\");";
	const c = compileProjectToCWithStd([{ entryPath: "test/e2e.ms", entrySource: src }], "test/e2e.ms");
	assert !c.startsWith("ERROR"), c;
	assert c.contains(" = eqeq___") && c.contains("return (!(__call_"), c;
}

test "E2E C: string param and return" {
	const src = "function echo(s: string): string { return s; }\nconst r = echo(\"test\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msString");
}
