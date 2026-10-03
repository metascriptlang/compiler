import { JsonValue, JsonKind } from "std/serialize/json/types";
import { jsonValueToStruct, jsonValueToStructE, parseJson } from "std/serialize/json";

interface Row {
	name: string;
	rank: int64;
}

interface Holder {
	v: JsonValue;
}

function decodeIndexed(items: JsonValue[]): Row[] {
	const out: Row[] = [];
	let i = 0;
	while (i < items.length) {
		out.push(jsonValueToStruct(items[i], null as Row | null));
		i = i + 1;
	}
	return out;
}

function decodeHoisted(items: JsonValue[]): Row[] {
	const out: Row[] = [];
	let i = 0;
	while (i < items.length) {
		const el: JsonValue = items[i];
		out.push(jsonValueToStruct(el, null as Row | null));
		i = i + 1;
	}
	return out;
}

function decodeMember(h: Holder): Row {
	return jsonValueToStruct(h.v, null as Row | null);
}

function decodeGeneric<T>(items: JsonValue[], witness: T | null): T[] {
	const out: T[] = [];
	let i = 0;
	while (i < items.length) {
		out.push(jsonValueToStruct(items[i], witness));
		i = i + 1;
	}
	return out;
}

const SRC = "[{\"name\":\"a\",\"rank\":1},{\"name\":\"b\",\"rank\":2}]";

function rowsOf(): JsonValue[] {
	const r = JSON.parseValue(SRC);
	if (!r.ok) return [];
	const v: JsonValue = r.value;
	if (v.kind != JsonKind.Array) return [];
	return v.items;
}

test "macro witness access: indexed hoisted and generic reads preserve every row field" {
	const contextual: Row[] = decodeGeneric(rowsOf(), null);
	const variants: Row[][] = [
		decodeIndexed(rowsOf()),
		decodeHoisted(rowsOf()),
		decodeGeneric<Row>(rowsOf(), null),
		contextual,
	];
	for (let route: int32 = 0; route < variants.length; route++) {
		const rows = variants[route];
		assert rows.length == 2, "route " + route.toString();
		assert rows[0].name == "a" && rows[0].rank == 1, "first row route " + route.toString();
		assert rows[1].name == "b" && rows[1].rank == 2, "second row route " + route.toString();
	}
}

test "macro witness access: MemberExpr macro argument keeps working" {
	const items = rowsOf();
	const h: Holder = { v: items[0] };
	const row = decodeMember(h);
	assert row.name == "a", "member name: " + row.name;
	assert row.rank == 1, "member rank: " + row.rank.toString();
}


enum WitnessKind { Alpha, Beta }

type WitnessEvent = match (kind: WitnessKind) {
	WitnessKind.Alpha => { xv: number },
	WitnessKind.Beta => { note: string },
};

test "macro nullable discriminator: enum-disc DU decodes through a `| null` witness" {
	const pr = parseJson(`{"kind":"Beta","note":"n"}`);
	assert pr.ok;
	const errs: string[] = [];
	const e: WitnessEvent = jsonValueToStructE(pr.value, null as WitnessEvent | null, errs, "");
	assert errs.length == 0;
	assert e.kind == WitnessKind.Beta;
	if (e.kind == WitnessKind.Beta) {
		assert e.note == "n";
	}
	const numeric = parseJson(`{"kind":"Alpha","xv":5}`);
	assert numeric.ok;
	const other: WitnessEvent = jsonValueToStructE(numeric.value, null as WitnessEvent | null, errs, "");
	assert errs.length == 0;
	assert other.kind == WitnessKind.Alpha;
	if (other.kind == WitnessKind.Alpha) assert other.xv == 5;
}

interface WitnessAddress { city: string; zip: int32; }

interface WitnessEmployee { name: string; addr: WitnessAddress; }

test "macro nested witness: inline-cast witness decodes a nested struct" {
	const pr = parseJson(`{"name":"a","addr":{"city":"HN","zip":100}}`);
	assert pr.ok;
	const errs: string[] = [];
	const v: WitnessEmployee = jsonValueToStructE(pr.value, null as WitnessEmployee | null, errs, "");
	assert errs.length == 0;
	assert v.addr.city == "HN";
	assert v.addr.zip == 100;
}

test "macro nested witness: JSON.parse facade decodes the same nested struct" {
	const r = JSON.parse<WitnessEmployee>(`{"name":"b","addr":{"city":"SG","zip":700}}`);
	assert r.ok;
	if (r.ok) {
		assert r.value.addr.zip == 700;
		assert r.value.name == "b" && r.value.addr.city == "SG";
	}
}

enum CodecKind { Click, Key }

interface CodecClick { kind: CodecKind.Click; x: int32; }

interface CodecKey { kind: CodecKind.Key; code: int32; }

type CodecEvent = CodecClick | CodecKey;

enum CodecColor { Red, Green, Blue }

enum CodecStatus { Active = 5, Inactive = 2 }

interface CodecPaint { name: string; c: CodecColor; s: CodecStatus; cs: CodecColor[]; }

interface CodecPalette { name: string; cs: CodecColor[]; }

test "macro enum codec: each narrowed discriminant round-trips with its payload" {
	const narrowed: CodecEvent = { kind: CodecKind.Click, x: 7 };
	assert JSON.stringify(narrowed) == `{"kind":"Click","x":7}`;
	const narrowedKey: CodecEvent = { kind: CodecKind.Key, code: 42 };
	const back = JSON.parse<CodecEvent>(JSON.stringify(narrowedKey));
	assert back.ok && back.value.kind == CodecKind.Key;
	const values: CodecEvent[] = [
		{ kind: CodecKind.Click, x: 7 },
		{ kind: CodecKind.Key, code: 42 },
	];
	for (const value of values) {
		const text = JSON.stringify(value);
		if (value.kind == CodecKind.Click) assert text == `{"kind":"Click","x":7}`;
		else assert text == `{"kind":"Key","code":42}`;
		const parsed = JSON.parse<CodecEvent>(text);
		assert parsed.ok;
		assert parsed.value.kind == value.kind;
	}
}

test "macro enum codec: a number where the discriminant enum is expected is an error naming the field" {
	const r = JSON.parse<CodecEvent>(`{"kind":1,"code":42}`);
	assert !r.ok && r.error.includes("field 'kind'");
}

test "macro enum codec: plain enum fields and enum array elements write member names, holey values included" {
	const p: CodecPaint = { name: "x", c: CodecColor.Blue, s: CodecStatus.Inactive, cs: [CodecColor.Green, CodecColor.Red] };
	assert JSON.stringify(p) == `{"name":"x","c":"Blue","s":"Inactive","cs":["Green","Red"]}`;
}

test "macro enum codec: an enum array reads member names back" {
	const r = JSON.parse<CodecPalette>(`{"name":"y","cs":["Blue","Red"]}`);
	assert r.ok && r.value.cs.length == 2 && r.value.cs[0] == CodecColor.Blue && r.value.cs[1] == CodecColor.Red;
}

test "macro enum codec: a number in an enum array is an error naming the element" {
	const r = JSON.parse<CodecPalette>(`{"name":"y","cs":["Blue",0]}`);
	assert !r.ok && r.error.includes("field 'cs[1]': expected CodecColor member name, got int");
}

test "macro enum codec: a plain enum field reads its member name, holey values included" {
	const pr = parseJson(`{"name":"y","c":"Green","s":"Inactive","cs":[]}`);
	const errs: string[] = [];
	const p: CodecPaint = jsonValueToStructE(pr.ok ? pr.value : jsonNull(), null as CodecPaint | null, errs, "");
	assert errs.length == 0 && p.c == CodecColor.Green && p.s == CodecStatus.Inactive;
}

test "macro enum codec: a number where a plain enum field is expected is an error naming the field" {
	const pr = parseJson(`{"name":"y","c":1,"s":"Busy","cs":[]}`);
	const errs: string[] = [];
	const p: CodecPaint = jsonValueToStructE(pr.ok ? pr.value : jsonNull(), null as CodecPaint | null, errs, "");
	assert p.name == "y" && errs.length == 2 &&
		errs[0] == "field 'c': expected CodecColor member name, got int" &&
		errs[1] == "field 's': 'Busy' is not a member of CodecStatus";
}

enum ContextColor { Red, Green, Blue }

type ContextUserId = int32;

interface ContextItem {
	name: string;
	count: int32;
}

function takeNull<T>(witness: T | null): T[] {
	return [];
}

test "macro witness contextual result: null witnesses specialize element storage from the result slot" {
	const colors: ContextColor[] = takeNull(null);
	const items: ContextItem[] = takeNull(null);
	const ids: ContextUserId[] = takeNull(null);
	assert colors.length == 0 && items.length == 0 && ids.length == 0;
	colors.push(ContextColor.Blue);
	items.push({ name: "stored", count: 3 });
	ids.push(41);
	assert colors[0] == ContextColor.Blue;
	assert items[0].name == "stored" && items[0].count == 3;
	assert ids[0] + 1 == 42;
}
