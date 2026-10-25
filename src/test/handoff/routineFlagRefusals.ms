import { refusedOnEveryBackend } from "../helpers";

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
