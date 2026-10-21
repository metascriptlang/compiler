import { checkOnly } from "../helpers";

const USER = `
interface User { id: int32; name: string; email?: string }
`;

test "Pick refuses a key that is not a key of its object type" {
	const text = checkOnly(USER + `
const a: Pick<User, "id" | "nope"> = { id: 1 };
`).errors.join("\n");
	assert text.contains(`type '"id" | "nope"' does not satisfy the constraint 'keyof User' of Pick`), "a key outside keyof User: " + text;
}

test "a mapped type that declares other members is refused" {
	const text = checkOnly(`
type Mixed = { [K in "a" | "b"]: int32; extra: string };
`).errors.join("\n");
	assert text.contains("a mapped type may not declare properties or methods"), "a property beside the mapped member: " + text;
}

test "a Record key that is no property name is refused" {
	const text = checkOnly(`
const f: Record<boolean, int32> = {};
`).errors.join("\n");
	assert text.contains("its key 'boolean' is no property name"), "boolean keys: " + text;
}

test "a Partial literal is held to the fields of its source" {
	const text = checkOnly(USER + `
const b: Partial<User> = { nope: 1 };
const g: Partial<User> = { name: 1 };
`).errors.join("\n");
	assert text.contains("'nope' does not exist in type '{ id: int32 | null; name: string | null; email: string | null; }'"), "an excess key: " + text;
	assert text.contains("Type 'int32' is not assignable to type 'string | null'"), "a wrong field type: " + text;
}

test "Required and -? take null out of a declared-optional field" {
	const text = checkOnly(USER + `
type Strict<T> = { [K in keyof T]-?: T[K] };
const c: Required<User> = { id: 1, name: "n", email: null };
const s: Strict<User> = { id: 1, name: "n", email: null };
`).errors.join("\n");
	assert text.split("Type 'null' is not assignable to type 'string'").length == 3, "null into a required email, twice: " + text;
}

test "a readonly mapped type and Readonly through an alias refuse a write" {
	const text = checkOnly(USER + `
type Frozen<T> = { readonly [K in keyof T]: T[K] };
type RO<T> = Readonly<T>;
const d: Frozen<User> = { id: 1, name: "n" };
d.id = 2;
const h: RO<User> = { id: 1, name: "n" };
h.name = "m";
`).errors.join("\n");
	assert text.split("cannot write through Readonly<User>").length == 3, "a write through Frozen<User> and through RO<User>: " + text;
}

test "the accepted forms check clean" {
	const errors = checkOnly(USER + `
type Mutable<T> = { -readonly [K in keyof T]: T[K] };
const p: Partial<User> = {};
const r: Required<User> = { id: 1, name: "n", email: "e" };
const k: Pick<User, "id"> = { id: 1 };
const o: Omit<User, "email"> = { id: 1, name: "n" };
const m: Mutable<Readonly<User>> = { id: 1, name: "n" };
m.id = 2;
const rec: Record<"x" | "y", int32> = { x: 1, y: 2 };
`).errors;
	assert errors.length == 0, "the utility types accept their TS forms: " + errors.join("\n");
}
