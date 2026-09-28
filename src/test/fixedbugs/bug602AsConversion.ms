// bug602 — `as` between a union and its member reinterpreted one C layout as another
//
// Symptom:    `v as Align | null` from `number | string | null` crashed on C, `v as Align` and
//             `v as string` did not compile, `a as Wire` from `Align | null` or `number | null`
//             crashed, `s as Align | null` from a string gave null, and a string outside a
//             string-literal union passed `as` unchecked on both backends.
// Root cause: the TypeAssertion arm built no conversion into or out of a nullable union and
//             none into a string-literal union, so C codegen reinterpreted one carrier as another.
// Fix:        widening takes the assignment's conversion, narrowing projects the member's slot
//             behind a tag test, and a string entering a string-literal union tests membership
//             (NodeFlag.ConvCheck); --danger drops both tests.

import { compileToC, compileToJS } from "../helpers";

const types = "type Align = \"auto\" | \"center\" | \"stretch\";\ntype Wire = number | string | null;\n"
	+ "function show(a: Align | null): string { if (a == null) return \"null\"; const t: string = a; return t; }\n";

const failed = "compile failed: ";

function cOf(body: string): string {
	const r = compileToC(types + body);
	return r.ok ? r.value : failed + r.error;
}

function jsOf(body: string): string {
	const r = compileToJS(types + body);
	return r.ok ? r.value : failed + r.error;
}

function built(text: string): boolean {
	return !text.startsWith(failed);
}

const strToLit = "function f(s: string): Align { return s as Align; }\nconsole.log(show(f(\"center\")));";
const strToLitN = "function f(s: string): Align | null { return s as Align | null; }\nconsole.log(show(f(\"center\")));";
const strNToLitN = "function f(s: string | null): Align | null { return s as Align | null; }\nconsole.log(show(f(\"center\")));";
const wireToLitN = "function f(v: Wire): Align | null { return v as Align | null; }\nconst w: Wire = \"center\";\nconsole.log(show(f(w)));";
const wireToLit = "function f(v: Wire): Align { return v as Align; }\nconst w: Wire = \"center\";\nconsole.log(show(f(w)));";
const wireToStr = "function f(v: Wire): string { return v as string; }\nconst w: Wire = \"center\";\nconsole.log(f(w));";
const litNToWire = "function f(a: Align | null): Wire { return a as Wire; }\nconst a: Align | null = \"auto\";\nconst w = f(a);\nconsole.log(w == null ? \"null\" : \"set\");";
const numNToWire = "function f(n: number | null): Wire { return n as Wire; }\nconst n: number | null = 4;\nconst w = f(n);\nconsole.log(w == null ? \"null\" : \"set\");";
const unionToStr = "function f(u: number | string): string { return u as string; }\nconsole.log(f(\"center\"));";

test "bug602: a string entering a string-literal union tests membership" {
	const c = cOf(strToLit);
	assert built(c), c;
	assert c.contains("msStrLitConv(");
}

test "bug602: a string entering a nullable string-literal union tests membership" {
	const c = cOf(strToLitN);
	assert built(c), c;
	assert c.contains("msStrLitConv(");
	assert !c.contains("*(Maybe_");
}

test "bug602: a nullable string entering a nullable string-literal union tests its payload" {
	const c = cOf(strNToLitN);
	assert built(c), c;
	assert c.contains("msStrLitConv(");
	assert !c.contains("*(Maybe_");
}

test "bug602: a nullable union narrows to a nullable string-literal union through its string slot" {
	const c = cOf(wireToLitN);
	assert built(c), c;
	assert c.contains("_mnarrow");
	assert c.contains("msStrLitConv(");
	assert !c.contains("*(Maybe_");
}

test "bug602: a nullable union narrows to its string member through the string slot" {
	const str = cOf(wireToStr);
	assert built(str), str;
	assert str.contains(".v1");
	const lit = cOf(wireToLit);
	assert built(lit), lit;
	assert lit.contains(".v1");
	assert lit.contains("msStrLitConv(");
}

test "bug602: widening into a nullable union rebuilds the carrier" {
	const lit = cOf(litNToWire);
	assert built(lit), lit;
	assert lit.contains("_mwiden");
	assert !lit.contains("*(Maybe_");
	const num = cOf(numNToWire);
	assert built(num), num;
	assert num.contains("_mwiden");
	assert !num.contains("*(Maybe_");
}

test "bug602: JS tests membership with the same message" {
	const bare = jsOf(strToLit);
	assert built(bare), bare;
	assert bare.contains("invalid union conversion: ");
	assert bare.contains("\"stretch\"");
	const nullable = jsOf(wireToLitN);
	assert built(nullable), nullable;
	assert nullable.contains("invalid union conversion: ");
}

test "bug602: JS tests the member of a bare union with the same message" {
	const js = jsOf(unionToStr);
	assert built(js), js;
	assert js.contains("typeof");
	assert js.contains("is not accessible for type");
}
