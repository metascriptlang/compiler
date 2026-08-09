// Language tests: JSON stringify + untyped parse via JsonValue accessors.
//
// Typed `JSON.parse<T>` runs on BOTH backends — the corpus exercises it on C
// and on node (505/506/509/510, byte-compared). This file stays on the untyped
// JsonValue paths on purpose: they are what the accessor API guarantees, and
// keeping them separate means a typed-decode regression shows up as a corpus
// parity failure rather than as noise in the language tier.

import { jsonValueToStruct, jsonValueToStructE, jsonValueOf } from "std/serialize/json";

interface Person {
	name: string;
	age: int32;
}

test "JSON.stringify typed struct" {
	const p: Person = { name: "Alice", age: 30 };
	const s = JSON.stringify(p);
	assert s === `{"name":"Alice","age":30}`;
}

test "JSON.stringify inline anonymous literal" {
	const s = JSON.stringify({ field: "value" });
	assert s === `{"field":"value"}`;
}

test "JSON.stringify nested literal" {
	const s = JSON.stringify({ a: 1, b: { c: 2 } });
	assert s === `{"a":1,"b":{"c":2}}`;
}

// ===== Strict typed decode — the MS type is the contract =====
// JSON.parse<T> must FAIL LOUD when the input does not satisfy T:
// missing field, wrong kind, non-object top level. Field names appear
// in the error so the caller can act on it.

test "typed parse: valid input still ok" {
	const r = JSON.parse<Person>(`{"name":"Alice","age":30}`);
	assert r.ok;
	assert r.value.name === "Alice";
	assert r.value.age === 30;
}

test "typed parse: empty object → err naming both fields" {
	const r = JSON.parse<Person>("{}");
	assert !r.ok;
	assert r.error === "field 'name': expected string, got null; field 'age': expected int, got null";
}

test "typed parse: wrong kinds → err per field" {
	const r = JSON.parse<Person>(`{"name":42,"age":"x"}`);
	assert !r.ok;
	assert r.error === "field 'name': expected string, got int; field 'age': expected int, got string";
}

test "typed parse: float for int field → err" {
	const r = JSON.parse<Person>(`{"name":"A","age":1.5}`);
	assert !r.ok;
	assert r.error === "field 'age': expected int, got number";
}

test "typed parse: top-level array → err" {
	const r = JSON.parse<Person>("[1,2]");
	assert !r.ok;
	assert r.error === "expected object at top level, got array";
}

test "typed parse: syntax error still reported first" {
	const r = JSON.parse<Person>("{oops");
	assert !r.ok;
}

interface Address {
	city: string;
	zip: int32;
}

interface Employee {
	name: string;
	addr: Address;
}

test "typed parse: nested struct missing field → err with dotted path" {
	const r = JSON.parse<Employee>(`{"name":"A","addr":{"city":"HN"}}`);
	assert !r.ok;
	assert r.error === "field 'addr.zip': expected int, got null";
}

test "typed parse: nested struct wrong top kind → err at field" {
	const r = JSON.parse<Employee>(`{"name":"A","addr":7}`);
	assert !r.ok;
}

interface Tagged {
	label: string;
	tags: string[];
}

test "typed parse: array field present and typed → ok" {
	const r = JSON.parse<Tagged>(`{"label":"x","tags":["a","b"]}`);
	assert r.ok;
	assert r.value.tags.length === 2;
}

test "typed parse: array field wrong kind → err" {
	const r = JSON.parse<Tagged>(`{"label":"x","tags":3}`);
	assert !r.ok;
	assert r.error === "field 'tags': expected array, got int";
}

test "typed parse: missing array field → err" {
	const r = JSON.parse<Tagged>(`{"label":"x"}`);
	assert !r.ok;
	assert r.error === "field 'tags': expected array, got null";
}

// ===== Tagged unions =====
// These go through the macro directly: JSON.parse<Shape> does not compile
// today because instantiating a generic with a union ALIAS loses the alias
// ("Unresolved type 'Shape'") — a checker gap, reported separately. The
// decode contract itself is what these pin down.

interface Circle {
	kind: "circle";
	r: number;
}

interface Square {
	kind: "square";
	s: number;
}

type Shape = Circle | Square;

// Decoded inline in each test: returning a DU through Result<Shape, string>
// hits a separate codegen gap (indirection on a by-value DU), unrelated to
// the decode contract under test here.

test "DU decode: known discriminator decodes that variant" {
	const pr = parseJson(`{"kind":"square","s":4}`);
	assert pr.ok;
	const errs: string[] = [];
	const s: Shape = jsonValueToStructE(pr.value, null as Shape | null, errs, "");
	assert errs.length === 0;
	assert s.kind === "square";
}

test "DU decode: unknown discriminator is an error, not the last variant" {
	// Before the wildcard arm existed this silently produced a Square.
	const pr = parseJson(`{"kind":"hexagon","r":1}`);
	assert pr.ok;
	const errs: string[] = [];
	const s: Shape = jsonValueToStructE(pr.value, null as Shape | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'kind': unknown discriminator value 'hexagon'";
}

test "DU decode: missing discriminator is an error" {
	const pr = parseJson(`{"r":1}`);
	assert pr.ok;
	const errs: string[] = [];
	const s: Shape = jsonValueToStructE(pr.value, null as Shape | null, errs, "");
	assert errs.length > 0;
}

test "DU decode: variant payload wrong kind is an error" {
	const pr = parseJson(`{"kind":"circle","r":"big"}`);
	assert pr.ok;
	const errs: string[] = [];
	const s: Shape = jsonValueToStructE(pr.value, null as Shape | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'r': expected number, got string";
}


// ===== Array-of-struct elements (roadmap 7) =====
//
// Exercised through jsonValueToStructE directly, like the DU tests above:
// the facade entry adds a generic-instantiation variable this file does not
// need in order to pin the element contract.

interface Line {
	sku: string;
	qty: int64;
}

interface Cart {
	items: Line[];
}

test "array of structs: elements decode" {
	const pr = parseJson(`{"items":[{"sku":"a","qty":2},{"sku":"b","qty":3}]}`);
	assert pr.ok;
	const errs: string[] = [];
	const c: Cart = jsonValueToStructE(pr.value, null as Cart | null, errs, "");
	assert errs.length === 0;
	assert c.items.length === 2;
	assert c.items[1].sku === "b";
	assert c.items[1].qty === 3;
}

test "array of structs: element field of the wrong kind is an error" {
	const pr = parseJson(`{"items":[{"sku":"a","qty":"two"}]}`);
	assert pr.ok;
	const errs: string[] = [];
	const c: Cart = jsonValueToStructE(pr.value, null as Cart | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'items[0].qty': expected int, got string";
}

test "array of structs: a missing element field is an error" {
	const pr = parseJson(`{"items":[{"sku":"a"}]}`);
	assert pr.ok;
	const errs: string[] = [];
	const c: Cart = jsonValueToStructE(pr.value, null as Cart | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'items[0].qty': expected int, got null";
}

test "array of structs: a non-object element is an error" {
	const pr = parseJson(`{"items":[7]}`);
	assert pr.ok;
	const errs: string[] = [];
	const c: Cart = jsonValueToStructE(pr.value, null as Cart | null, errs, "");
	assert errs.length > 0;
	assert errs[0] === "field 'items[0]': expected object, got int";
}

test "array of structs: the second element reports its own index" {
	const pr = parseJson(`{"items":[{"sku":"a","qty":1},{"sku":"b"}]}`);
	assert pr.ok;
	const errs: string[] = [];
	const c: Cart = jsonValueToStructE(pr.value, null as Cart | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'items[1].qty': expected int, got null";
}

// ===== Atomic array elements are strict too =====
//
// Struct elements became strict first; atomic elements stayed lenient and
// silently fabricated a default (`["a",7]` for string[] produced ["a",""]).
// The type is the contract at every depth, so the element index appears in
// the path exactly as it does for struct elements.

interface Bag {
	xs: string[];
}

interface Nums {
	ns: int64[];
}

interface Flags {
	bs: boolean[];
}

test "atomic array elements: all-good still decodes" {
	const pr = parseJson(`{"xs":["a","b"]}`);
	assert pr.ok;
	const errs: string[] = [];
	const b: Bag = jsonValueToStructE(pr.value, null as Bag | null, errs, "");
	assert errs.length === 0;
	assert b.xs.length === 2;
	assert b.xs[1] === "b";
}

test "atomic array elements: wrong element kind is an error" {
	const pr = parseJson(`{"xs":["a",7]}`);
	assert pr.ok;
	const errs: string[] = [];
	const b: Bag = jsonValueToStructE(pr.value, null as Bag | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'xs[1]': expected string, got int";
}

test "atomic array elements: null element is an error" {
	const pr = parseJson(`{"xs":["a",null]}`);
	assert pr.ok;
	const errs: string[] = [];
	const b: Bag = jsonValueToStructE(pr.value, null as Bag | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'xs[1]': expected string, got null";
}

test "atomic array elements: float in an int64 array is an error" {
	const pr = parseJson(`{"ns":[1,1.5]}`);
	assert pr.ok;
	const errs: string[] = [];
	const n: Nums = jsonValueToStructE(pr.value, null as Nums | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'ns[1]': expected int, got number";
}

test "atomic array elements: wrong kind in a boolean array is an error" {
	const pr = parseJson(`{"bs":[true,"x"]}`);
	assert pr.ok;
	const errs: string[] = [];
	const f: Flags = jsonValueToStructE(pr.value, null as Flags | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'bs[1]': expected boolean, got string";
}

// ===== Enum-discriminated unions (roadmap 8) =====
//
// Wire format is fixed by encode: the disc travels as the member NAME string
// (`{"kind":"Click",...}`), never the numeric value. Decode reads the string,
// gates it against the declared member names, and constructs the variant with
// the real enum member — the name→value mapping is the checker resolving the
// emitted `EvKind.Click`, not a number baked in at expansion time.

enum EvKind { Click, KeyPress }

type Event = match (kind: EvKind) {
	EvKind.Click => { x: number, y: number },
	EvKind.KeyPress => { code: string },
};

test "enum DU decode: known member name decodes that variant" {
	const pr = parseJson(`{"kind":"Click","x":1,"y":2}`);
	assert pr.ok;
	const errs: string[] = [];
	const e: Event = jsonValueToStructE(pr.value, null as Event | null, errs, "");
	assert errs.length === 0;
	assert e.kind === EvKind.Click;
	if (e.kind === EvKind.Click) {
		assert e.x === 1;
		assert e.y === 2;
	}
}

test "enum DU decode: unknown member name is an error, not a variant" {
	// Payload satisfies variant[0] (the gate's fallback arm) so the ONLY
	// error is the disc — same shape as the string-disc 'hexagon' test.
	const pr = parseJson(`{"kind":"Hover","x":1,"y":2}`);
	assert pr.ok;
	const errs: string[] = [];
	const e: Event = jsonValueToStructE(pr.value, null as Event | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'kind': unknown discriminator value 'Hover'";
}

test "enum DU decode: missing discriminator is an error" {
	const pr = parseJson(`{"x":1}`);
	assert pr.ok;
	const errs: string[] = [];
	const e: Event = jsonValueToStructE(pr.value, null as Event | null, errs, "");
	assert errs.length > 0;
}

test "enum DU decode: variant payload wrong kind is an error" {
	const pr = parseJson(`{"kind":"KeyPress","code":7}`);
	assert pr.ok;
	const errs: string[] = [];
	const e: Event = jsonValueToStructE(pr.value, null as Event | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'code': expected string, got int";
}

test "enum DU decode: round trips encode's wire format" {
	const ev: Event = { kind: EvKind.KeyPress, code: "Esc" };
	const tree = jsonValueOf(ev);
	const errs: string[] = [];
	const back: Event = jsonValueToStructE(tree, null as Event | null, errs, "");
	assert errs.length === 0;
	if (back.kind === EvKind.KeyPress) {
		assert back.code === "Esc";
	} else {
		assert false;
	}
}

// ===== Nullable (optional) fields — `T | null` =====
// The docs/JSON.md contract: an optional field is SPELLED `T | null`.
// Missing ≡ null (both are the jsonNull sentinel) → decodes to null, no
// error. A present value of the wrong kind is still an error.

interface OptProfile {
	name: string;
	nick: string | null;
	age: int32 | null;
}

test "nullable field: present values decode" {
	const pr = parseJson(`{"name":"a","nick":"n","age":7}`);
	assert pr.ok;
	const errs: string[] = [];
	const p: OptProfile = jsonValueToStructE(pr.value, null as OptProfile | null, errs, "");
	assert errs.length === 0;
	assert p.name === "a";
	if (p.nick !== null) { assert p.nick === "n"; } else { assert false; }
	if (p.age !== null) { assert p.age === 7; } else { assert false; }
}

test "nullable field: explicit null decodes to null" {
	const pr = parseJson(`{"name":"a","nick":null,"age":null}`);
	assert pr.ok;
	const errs: string[] = [];
	const p: OptProfile = jsonValueToStructE(pr.value, null as OptProfile | null, errs, "");
	assert errs.length === 0;
	assert p.nick === null;
	assert p.age === null;
}

test "nullable field: absent decodes to null (missing is null)" {
	const pr = parseJson(`{"name":"a"}`);
	assert pr.ok;
	const errs: string[] = [];
	const p: OptProfile = jsonValueToStructE(pr.value, null as OptProfile | null, errs, "");
	assert errs.length === 0;
	assert p.nick === null;
	assert p.age === null;
}

test "nullable field: wrong kind is still an error" {
	const pr = parseJson(`{"name":"a","nick":42,"age":7}`);
	assert pr.ok;
	const errs: string[] = [];
	const p: OptProfile = jsonValueToStructE(pr.value, null as OptProfile | null, errs, "");
	assert errs.length === 1;
	assert errs[0] === "field 'nick': expected string, got int";
}

test "nullable field: works through JSON.parse<T>" {
	const r = JSON.parse<OptProfile>(`{"name":"a","nick":null,"age":3}`);
	assert r.ok;
	if (r.ok) {
		assert r.value.nick === null;
		if (r.value.age !== null) { assert r.value.age === 3; } else { assert false; }
	}
}

test "enum DU decode: lenient macro decodes a known member too" {
	const pr = parseJson(`{"kind":"Click","x":3,"y":4}`);
	assert pr.ok;
	const e: Event = jsonValueToStruct(pr.value, null as Event | null);
	assert e.kind === EvKind.Click;
	if (e.kind === EvKind.Click) {
		assert e.x === 3;
	}
}
