import { compileToC } from "../helpers";

function module(decorate: boolean, kind: string): string {
	const mark = (text: string): string => decorate ? text : "";
	return `
function tag(): void {}
function seeds(first: string, second: string): void {}
${kind} Accounts {
	${mark("@tag @seeds(\"config\", mint) ")}maker: int32;
	${mark("@tag ")}taker: int64;
	flag: boolean;
}
const a: Accounts = { maker: 1, taker: 2, flag: true };
console.log(a.maker);
`;
}

test "struct field decorators: a decorated struct emits the same C as the plain one" {
	const decorated = compileToC(module(true, "struct"));
	const plain = compileToC(module(false, "struct"));
	assert decorated.ok, decorated.ok ? "" : decorated.error;
	assert plain.ok, plain.ok ? "" : plain.error;
	if (decorated.ok && plain.ok) assert decorated.value == plain.value;
}

test "struct field decorators: a decorated interface emits the same C as the plain one" {
	const decorated = compileToC(module(true, "interface"));
	const plain = compileToC(module(false, "interface"));
	assert decorated.ok, decorated.ok ? "" : decorated.error;
	assert plain.ok, plain.ok ? "" : plain.error;
	if (decorated.ok && plain.ok) assert decorated.value == plain.value;
}

test "struct field decorators: an unresolved decorator name is an error naming it" {
	const c = compileToC("struct S { @nosuch a: int32; }\nconst s: S = { a: 1 };\nconsole.log(s.a);");
	assert !c.ok;
	if (!c.ok) assert c.error.contains("Cannot find name 'nosuch'");
}

test "struct field decorators: an unresolved name on an interface field is the same error" {
	const c = compileToC("interface I { @nosuch a: int32; }\nconst i: I = { a: 1 };\nconsole.log(i.a);");
	assert !c.ok;
	if (!c.ok) assert c.error.contains("Cannot find name 'nosuch'");
}

test "struct field decorators: only the unresolved decorator among resolved ones is reported" {
	const c = compileToC("function tag(): void {}\nstruct S { @tag @nosuch a: int32; @tag b: int32; }\nconsole.log(1);");
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("Cannot find name 'nosuch'");
		assert !c.error.contains("Cannot find name 'tag'");
	}
}

test "struct field decorators: a decorator name that is not callable is an error naming it" {
	const c = compileToC("const limit = 5;\nstruct S { @limit a: int32; }\nconsole.log(1);");
	assert !c.ok;
	if (!c.ok) assert c.error.contains("'limit' is not callable as a decorator");
}

test "struct field decorators: arguments are syntax and are never resolved" {
	const c = compileToC("function seeds(first: string, second: string): void {}\nstruct S { @seeds(\"x\", neverDeclared) @seeds(nothing.here, call.nowhere()) a: int32; }\nconsole.log(1);");
	assert c.ok, c.ok ? "" : c.error;
}
