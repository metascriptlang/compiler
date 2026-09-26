// bug301 — JSON wrote an enum as its ordinal wherever the static type was the enum
//
// Symptom:    `const e: Ev = { kind: EvKind.Click, x: 7 }; JSON.stringify(e)` gave
//             `{"kind":0,"x":7}`, and the round trip through `JSON.parse<Ev>` failed:
//             the union decoder reads the member name, the variant the value was
//             narrowed to wrote the number. Plain enum fields and enum arrays wrote
//             numbers too, and an enum array decoded numbers.
// Root cause: the macro bridge rendered an enum-literal type (`EvKind.Click`) as the
//             enum's bare name, so the encoder took it for an integer alias; the
//             encoder sent every enum through `jsonInt(v as int64)`.
// Fix:        the bridge renders an enum-literal type as `EvKind.Click` and carries
//             enum member values to macros; the codec writes a member name at every
//             position and reads only a name (Nim json.nim `%`(enum), initFromJson for
//             enums), through member name/value tables emitted per enum.

import { parseJson, jsonValueToStructE } from "std/serialize/json";

enum B301Kind { Click, Key }
interface B301Click { kind: B301Kind.Click; x: int32; }
interface B301Key { kind: B301Kind.Key; code: int32; }
type B301Ev = B301Click | B301Key;

enum B301Color { Red, Green, Blue }
enum B301Status { Active = 5, Inactive = 2 }
interface B301Paint { name: string; c: B301Color; s: B301Status; cs: B301Color[]; }
interface B301Palette { name: string; cs: B301Color[]; }

test "bug301: a variant narrowed from an enum-discriminated union writes its discriminant by name" {
	const e: B301Ev = { kind: B301Kind.Click, x: 7 };
	assert JSON.stringify(e) == `{"kind":"Click","x":7}`;
}

test "bug301: the narrowed variant's JSON parses back into the union" {
	const k: B301Ev = { kind: B301Kind.Key, code: 42 };
	const r = JSON.parse<B301Ev>(JSON.stringify(k));
	assert r.ok && r.value.kind == B301Kind.Key;
}

test "bug301: a number where the discriminant enum is expected is an error naming the field" {
	const r = JSON.parse<B301Ev>(`{"kind":1,"code":42}`);
	assert !r.ok && r.error.includes("field 'kind'");
}

test "bug301: plain enum fields and enum array elements write member names, holey values included" {
	const p: B301Paint = { name: "x", c: B301Color.Blue, s: B301Status.Inactive, cs: [B301Color.Green, B301Color.Red] };
	assert JSON.stringify(p) == `{"name":"x","c":"Blue","s":"Inactive","cs":["Green","Red"]}`;
}

test "bug301: an enum array reads member names back" {
	const r = JSON.parse<B301Palette>(`{"name":"y","cs":["Blue","Red"]}`);
	assert r.ok && r.value.cs.length == 2 && r.value.cs[0] == B301Color.Blue && r.value.cs[1] == B301Color.Red;
}

test "bug301: a number in an enum array is an error naming the element" {
	const r = JSON.parse<B301Palette>(`{"name":"y","cs":["Blue",0]}`);
	assert !r.ok && r.error.includes("field 'cs[1]': expected B301Color member name, got int");
}

test "bug301: a plain enum field reads its member name, holey values included" {
	const pr = parseJson(`{"name":"y","c":"Green","s":"Inactive","cs":[]}`);
	const errs: string[] = [];
	const p: B301Paint = jsonValueToStructE(pr.ok ? pr.value : jsonNull(), null as B301Paint | null, errs, "");
	assert errs.length == 0 && p.c == B301Color.Green && p.s == B301Status.Inactive;
}

test "bug301: a number where a plain enum field is expected is an error naming the field" {
	const pr = parseJson(`{"name":"y","c":1,"s":"Busy","cs":[]}`);
	const errs: string[] = [];
	const p: B301Paint = jsonValueToStructE(pr.ok ? pr.value : jsonNull(), null as B301Paint | null, errs, "");
	assert p.name == "y" && errs.length == 2 && errs[0] == "field 'c': expected B301Color member name, got int"
		&& errs[1] == "field 's': 'Busy' is not a member of B301Status";
}
