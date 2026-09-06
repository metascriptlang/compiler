// bug077 — an array element passed as a MACRO ARGUMENT was dereferenced twice.
//
// Symptom:    `macro(arr[i], ...)` emitted `msRefArrayAccess((*(*arr)), i)` and
//             clang rejected it ("indirection requires pointer operand
//             ('msRefArray' invalid)"). Hoisting the element into a local first
//             compiled fine, and the same expression written outside a macro was
//             always fine. MemberExpr args (`h.v`) were unaffected.
// Root cause: re-checking a HiddenDeref node overwrote its own nodeType with the
//             CHILD's type — i.e. the still-Ref type — so ArrayAccess saw a Ref
//             operand a second time and inserted another HiddenDeref. Reference:
//             the deref node's type is set once at creation (semcall.nim:896
//             `tryDeref`: `typ = n.typ.skipTypes(abstractInst)[0]`) and re-sem
//             NEVER touches it (semexprs.nim:3531 recurses into the child only).
//             The re-check happens at all because macro args are rebuilt by the
//             bridge, which drops both nodeType and the Sem flag.
// Fix:        checkExpr's HiddenDeref branch keeps an existing nodeType and, when
//             absent, peels the Ref exactly like tryDeref does.
//
// Assert on READ-BACK FIELD VALUES, not just lengths — a wrong pointer can still
// produce the right element count.

import { JsonValue, JsonKind } from "std/serialize/json/types";
import { jsonValueToStruct } from "std/serialize/json";

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
	// Narrow to the Array variant — `items` exists only there (the strict
	// union-subset read rule); SRC is always a top-level array.
	if (v.kind != JsonKind.Array) return [];
	return v.items;
}

test "bug077: ArrayAccess as a macro argument derefs exactly once" {
	const rows = decodeIndexed(rowsOf());
	assert rows.length == 2, "count: " + rows.length.toString();
	assert rows[0].name == "a", "row0 name: " + rows[0].name;
	assert rows[1].name == "b", "row1 name: " + rows[1].name;
	assert rows[1].rank == 2, "row1 rank: " + rows[1].rank.toString();
}

test "bug077: hoisted element still decodes identically" {
	const indexed = decodeIndexed(rowsOf());
	const hoisted = decodeHoisted(rowsOf());
	assert hoisted.length == indexed.length;
	assert hoisted[0].name == indexed[0].name, "hoisted row0: " + hoisted[0].name;
	assert hoisted[1].rank == indexed[1].rank, "hoisted row1: " + hoisted[1].rank.toString();
}

test "bug077: MemberExpr macro argument keeps working" {
	const items = rowsOf();
	const h: Holder = { v: items[0] };
	const row = decodeMember(h);
	assert row.name == "a", "member name: " + row.name;
	assert row.rank == 1, "member rank: " + row.rank.toString();
}

test "bug077: ArrayAccess macro argument inside a generic body" {
	const rows: Row[] = decodeGeneric(rowsOf(), null);
	assert rows.length == 2, "generic count: " + rows.length.toString();
	assert rows[0].name == "a", "generic row0: " + rows[0].name;
	assert rows[1].rank == 2, "generic row1 rank: " + rows[1].rank.toString();
}
