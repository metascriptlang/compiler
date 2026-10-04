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
	assert js.value.contains("type 'number | int32[]'");
}
