import { compileToJS } from "../helpers";

const ALIGN_PRELUDE = "type Align = \"auto\" | \"center\" | \"stretch\";\ntype Wire = number | string | null;\n"
	+ "function show(a: Align | null): string { if (a == null) return \"null\"; const t: string = a; return t; }\n";

test "JS: an as from a string into a string-literal union tests every member and names the union" {
	const js = compileToJS(ALIGN_PRELUDE + "function f(s: string): Align { return s as Align; }\nconsole.log(show(f(\"center\")));");
	assert js.ok;
	assert js.value.contains("v === \"auto\"");
	assert js.value.contains("v === \"center\"");
	assert js.value.contains("v === \"stretch\"");
	assert js.value.contains("invalid union conversion: ");
	assert js.value.contains("is not Align");
}

test "JS: an as from a nullable union into a nullable string-literal union tests membership" {
	const js = compileToJS(ALIGN_PRELUDE + "function f(v: Wire): Align | null { return v as Align | null; }\nconst w: Wire = \"center\";\nconsole.log(show(f(w)));");
	assert js.ok;
	assert js.value.contains("invalid union conversion: ");
}

test "JS: an as from a bare union to a member tests its typeof tag with the C message" {
	const js = compileToJS(ALIGN_PRELUDE + "function f(u: number | string): string { return u as string; }\nconsole.log(f(\"center\"));");
	assert js.ok;
	assert js.value.contains("typeof v === \"string\"");
	assert js.value.contains("member 'string' is not accessible for type 'number | string' using '");
}

test "JS: an as up to a base class out of a union with a subclass member tests instanceof the base" {
	const js = compileToJS("class Base { n: int32 = 1; }\nclass Child extends Base { k: int32 = 2; }\nfunction f(u: number | Base | Child): Base { return u as Base; }");
	assert js.ok;
	assert js.value.contains("v instanceof Base");
}

test "JS: a union access error names an array member by its element type" {
	const js = compileToJS("function f(u: number | int32[]): number { return u as number; }");
	assert js.ok;
	assert js.value.contains("type 'int32[] | number'");
}

test "JS: an as to the only array member of a union tests Array.isArray" {
	const js = compileToJS("function f(u: number | int32[]): int32[] { return u as int32[]; }");
	assert js.ok;
	assert js.value.contains("Array.isArray(v)");
}

test "JS: an as to the only plain-object member of a union excludes the union's classes" {
	const js = compileToJS("class Row { v: int32 = 1; }\ninterface Named { name: string; }\nfunction f(u: Row | Named): Named { return u as Named; }");
	assert js.ok;
	assert js.value.contains("!(v instanceof Row");
}

test "JS: an as to an int32 member tests the member before truncating" {
	const js = compileToJS("function f(u: int32 | string): int32 { return u as int32; }");
	assert js.ok;
	assert js.value.contains("typeof v === \"number\"");
}

test "JS: an as out of two same-kind struct members reads the member through its stored tag" {
	const js = compileToJS("struct P { a: int32 }\nstruct Q { b: int32 }\nfunction mk(): P | Q { const q: Q = { b: 2 }; return q; }\nfunction f(): int32 { const p = mk() as P; return p.a; }");
	assert js.ok;
	assert js.value.contains("$tag: 1");
	assert js.value.contains("msUnionRead");
	assert js.value.contains("member 'P' is not accessible for type 'P | Q' using '");
}

test "JS: an as out of int32 | float64 reads the member through its stored tag" {
	const js = compileToJS("function mk(): int32 | float64 { return 1.5; }\nfunction f(): int32 { return mk() as int32; }");
	assert js.ok;
	assert js.value.contains("$tag: 0, $v: 1.5");
	assert js.value.contains("member 'int32' is not accessible for type 'float64 | int32' using '");
}

test "JS: a union whose members the value names keeps the raw value" {
	const js = compileToJS("function mk(): number | string { return 1; }\nfunction f(): number { return mk() as number; }");
	assert js.ok;
	assert !js.value.contains("$tag");
}

test "JS: a union value returned by a host function is refused" {
	const js = compileToJS("extern function pick(k: int32): int32 | float64 from \"(#)\";\nconst v = pick(2);");
	assert !js.ok;
	assert js.error.contains("carries no tag naming its member");
}
