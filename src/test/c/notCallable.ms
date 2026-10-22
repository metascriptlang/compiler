// A value with no call signature is refused in call position (TS 2349) —
// a struct, a union of them, a reference to one, as much as a number. A
// struct or union that reached C there failed as "called object type is not
// a function", or as a JS TypeError.

import { compileToC, compileToJS } from "../helpers";

function callError(source: string): string {
	const c = compileToC(source);
	return c.ok ? "compiled" : c.error;
}

function jsCallError(source: string): string {
	const j = compileToJS(source);
	return j.ok ? "compiled" : j.error;
}

test "not callable: a struct, a union and a reference to them in call position" {
	assert callError("struct S { n: int32; }\nconst s: S = { n: 1 };\nfunction f(): void { s(1); }").contains("has no call signatures");
	assert callError("interface B { n: int32; }\nconst b: B = { n: 1 };\nfunction f(): void { b(); }").contains("has no call signatures");
	assert callError("type U = { k: \"a\"; n: int32 } | { k: \"b\"; s: string };\nconst u: U = { k: \"a\", n: 1 };\nfunction f(): void { u(); }").contains("has no call signatures");
}

test "not callable: a closure field and a nullable closure stay callable" {
	assert callError("struct H { run: () => int32; }\nconst h: H = { run: (): int32 => 1 };\nconsole.log(h.run());") == "compiled";
	assert callError("let g: (() => int32) | null = (): int32 => 2;\nif (g != null) console.log(g());") == "compiled";
}

test "not callable: a parameter, a local or a field named like a module function is called by its own type" {
	const fn = "function request(name: string): string { return name; }\n";
	const param = fn + "interface Options { size: number; }\nfunction run(request: Options): string { return request(\"x\"); }";
	const local = fn + "function run(): string { const request: number = 3; return request(\"x\"); }";
	const field = fn + "struct Inner { size: number; }\nstruct Options { request: Inner; }\nfunction run(o: Options): string { return o.request(\"x\"); }";
	assert callError(param).contains("type 'Options' has no call signatures");
	assert jsCallError(param).contains("type 'Options' has no call signatures");
	assert callError(local).contains("type 'number' has no call signatures");
	assert jsCallError(local).contains("type 'number' has no call signatures");
	assert callError(field).contains("type 'Inner' has no call signatures");
	assert jsCallError(field).contains("type 'Inner' has no call signatures");
}
