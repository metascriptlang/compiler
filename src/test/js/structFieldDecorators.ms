import { compileToJS } from "../helpers";

function module(decorate: boolean, kind: string): string {
	const mark = (text: string): string => decorate ? text : "";
	return `
function tag(): void {}
function seeds(first: string, second: string): void {}
${kind} Accounts {
	${mark("@tag @seeds(\"config\", mint) ")}maker: int32;
	${mark("@tag ")}taker: int64;
}
const a: Accounts = { maker: 1, taker: 2 };
console.log(a.maker);
`;
}

test "struct field decorators: a decorated struct emits the same JS as the plain one" {
	const decorated = compileToJS(module(true, "struct"));
	const plain = compileToJS(module(false, "struct"));
	assert decorated.ok, decorated.ok ? "" : decorated.error;
	assert plain.ok, plain.ok ? "" : plain.error;
	if (decorated.ok && plain.ok) assert decorated.value == plain.value;
}

test "struct field decorators: a decorated interface emits the same JS as the plain one" {
	const decorated = compileToJS(module(true, "interface"));
	const plain = compileToJS(module(false, "interface"));
	assert decorated.ok, decorated.ok ? "" : decorated.error;
	assert plain.ok, plain.ok ? "" : plain.error;
	if (decorated.ok && plain.ok) assert decorated.value == plain.value;
}

test "struct field decorators: an unresolved decorator name is an error naming it on the JS path too" {
	const c = compileToJS("struct S { @nosuch a: int32; }\nconst s: S = { a: 1 };\nconsole.log(s.a);");
	assert !c.ok;
	if (!c.ok) assert c.error.contains("Cannot find name 'nosuch'");
}
