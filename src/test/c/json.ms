// E2E: typed JSON.parse<T> + JSON.stringify → C output
// Migrated from examples/json.ms — covers the post-Result-migration fix in
// `checkDiscriminatedConstruction` (BooleanLiteral disc value extraction).
// Without that fix, `Result.ok({...})` synthesized by `__jsonParse_T` failed
// to stamp the inner literal as T — emitting `T* = anon_struct` C errors.

import { compileToC } from "../helpers";

test "E2E C: JSON.parse<Person> typed parse compiles" {
	const src = `
interface Person { name: string; age: int32; }

function main(): void {
	const r = JSON.parse<Person>("{\\"name\\":\\"Alice\\",\\"age\\":30}");
	if (r.ok) {
		const p = r.value;
		const _name = p.name;
		const _age = p.age;
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JSON round-trip (stringify + typed parse) compiles" {
	const src = `
interface Person { name: string; age: int32; }

function main(): void {
	const p: Person = { name: "Bob", age: 25 };
	const s = JSON.stringify(p);
	const r = JSON.parse<Person>(s);
	if (r.ok) { const out = r.value; }
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: untyped JSON.parse with JsonValue accessors compiles" {
	const src = `
function main(): void {
	const r = JSON.parse("{\\"status\\":\\"ok\\",\\"count\\":3}");
	if (r.ok) {
		const v = r.value;
		const _s = v.status.asString();
		const _n = v.count.asInt(0);
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}
