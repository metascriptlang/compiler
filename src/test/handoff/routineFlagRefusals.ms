import { refusedOnEveryBackend, compileToC, compileToJS, raiserErrors } from "../helpers";

test "routineFlagRefusals: an async extension function with a bare return type is refused like a plain one" {
	const extension = refusedOnEveryBackend("struct Box { v: int32; }\nasync function get(this b: Box): int32 { return b.v; }\nconst box: Box = { v: 7 };\nconsole.log(`${await box.get()}`);", "async function 'get' must declare return type as Promise<int32>");
	assert extension == "", extension;
	const generic = refusedOnEveryBackend("async function id<T>(x: T): T { return x; }\nconsole.log(`${await id(7)}`);", "async function 'id' must declare return type as Promise<");
	assert generic == "", generic;
}

test "routineFlagRefusals: an async actor method is refused whatever else its flags carry" {
	const generic = refusedOnEveryBackend("actor Counter {\n\tn: int32 = 0;\n\tasync bump<T>(x: T): void { this.n += 1; }\n}\nconsole.log(\"done\");", "actor methods are inherently async — remove 'async' from 'bump'");
	assert generic == "", generic;
	const asyncGenerator = refusedOnEveryBackend("actor Counter {\n\tn: int32 = 0;\n\tasync *items() { yield 1; }\n}\nconsole.log(\"done\");", "actor methods are inherently async — remove 'async' from 'items'");
	assert asyncGenerator == "", asyncGenerator;
}

test "routineFlagRefusals: an actor generator method is refused whatever else its flags carry" {
	const generic = refusedOnEveryBackend("actor Counter {\n\tn: int32 = 0;\n\t*items<T>(x: T) { yield 1; }\n}\nconsole.log(\"done\");", "actor methods cannot be generators — 'items'");
	assert generic == "", generic;
	const asyncGenerator = refusedOnEveryBackend("actor Counter {\n\tn: int32 = 0;\n\tasync *items() { yield 1; }\n}\nconsole.log(\"done\");", "actor methods cannot be generators — 'items'");
	assert asyncGenerator == "", asyncGenerator;
}

test "routineFlagRefusals: an async method, arrow or function expression with a bare return type is refused like a plain function" {
	const method = refusedOnEveryBackend("class C { async m(): int32 { return 1; } }\nconst c = new C();\nconsole.log(`${await c.m()}`);", "async function 'm' must declare return type as Promise<int32>, not bare 'int32'");
	assert method == "", method;
	const staticMethod = refusedOnEveryBackend("class C { static async m(): string { return \"s\"; } }\nconsole.log(await C.m());", "async function 'm' must declare return type as Promise<string>, not bare 'string'");
	assert staticMethod == "", staticMethod;
	const genericMethod = refusedOnEveryBackend("class C { async id<T>(x: T): T { return x; } }\nconst c = new C();\nconsole.log(`${await c.id(7)}`);", "async function 'id' must declare return type as Promise<T>");
	assert genericMethod == "", genericMethod;
	const arrow = refusedOnEveryBackend("const f = async (): int32 => 1;\nconsole.log(`${await f()}`);", "async function '<arrow>' must declare return type as Promise<int32>, not bare 'int32'");
	assert arrow == "", arrow;
	const expression = refusedOnEveryBackend("const f = async function (): int32 { return 1; };\nconsole.log(`${await f()}`);", "async function '(anon)' must declare return type as Promise<int32>, not bare 'int32'");
	assert expression == "", expression;
}

test "routineFlagRefusals: an async actor method reports only that actor methods are already async" {
	const c = compileToC("actor A { async m(): int32 { return 1; } }\nconsole.log(\"done\");");
	assert !c.ok;
	assert c.error.includes("actor methods are inherently async — remove 'async' from 'm'"), c.error;
	assert !c.error.includes("must declare return type"), c.error;
}

test "routineFlagRefusals: async methods, arrows and expressions declaring Promise<T> or void still compile" {
	const source = "class C {\n\tasync m(): Promise<int32> { return 1; }\n\tstatic async s(): Promise<int32> { return 2; }\n\tasync v(): void { console.log(\"v\"); }\n\tasync *g() { yield 3; }\n}\nconst c = new C();\nconst f = async (): Promise<int32> => 4;\nconst e = async function (): Promise<int32> { return 5; };\nconsole.log(`${await c.m()} ${await C.s()} ${await f()} ${await e()}`);\nawait c.v();";
	const c = compileToC(source);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileToJS(source);
	assert js.ok, js.ok ? "" : js.error;
	const raiser = raiserErrors(source);
	assert raiser == "", raiser;
}
