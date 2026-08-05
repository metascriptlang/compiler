// Language tests: JSON stringify + untyped parse via JsonValue accessors.
//
// Runtime caveat: JSON.parse<T> (typed) is a C-backend-only feature — the
// checker synthesizes per-type `__jsonParse_T` helpers. Typed-parse coverage
// lives in `src/test/c/json.ms` (compile-check). Here we exercise the paths
// that work uniformly across backends.

import { jsonValueToStructE } from "std/serialize/json";

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
