import { checkOnly } from "../helpers";

const SRC_PARAMETER = `
function f(x: object): void {}
`;

const SRC_VARIABLE = `
let y: object = [1];
`;

const SRC_PRIMITIVE_ARGUMENT = `
function keyed<T extends object>(x: T): string { return "keyed"; }
keyed("s");
keyed(1 as int32);
`;

const SRC_TESTS = `
class Pet { name: string = "p"; }
type Kind<V> = V extends object ? "node" : "leaf";
function keyed<T extends object>(x: T): string { return "keyed"; }
const a: Kind<Pet> = "node";
const b: Kind<string> = "leaf";
const c = keyed(new Pet()) + keyed([1]);
`;

test "a parameter typed object is refused" {
	const text = checkOnly(SRC_PARAMETER).errors.join("\n");
	assert text.contains("'object' only tests a type here, after 'extends'"), "a parameter typed object must fail the checker: " + text;
}

test "a variable typed object is refused" {
	const text = checkOnly(SRC_VARIABLE).errors.join("\n");
	assert text.contains("'object' only tests a type here, after 'extends'"), "a variable typed object must fail the checker: " + text;
}

test "a primitive does not satisfy an object constraint" {
	const text = checkOnly(SRC_PRIMITIVE_ARGUMENT).errors.join("\n");
	assert text.contains("Type 'string' does not satisfy constraint 'object'"), "a string must not satisfy T extends object: " + text;
	assert text.contains("Type 'int32' does not satisfy constraint 'object'"), "an int32 must not satisfy T extends object: " + text;
}

test "object after extends checks" {
	const result = checkOnly(SRC_TESTS);
	assert result.errors.length == 0, "object in a conditional and a constraint must check: " + result.errors.join("\n");
}
