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
