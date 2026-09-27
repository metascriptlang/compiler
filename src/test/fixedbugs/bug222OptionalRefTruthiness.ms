// bug222 — `if (b)` on a nullable reference lowered to a string byteLength read
//
// Symptom:    a condition on a nullable class/interface reference read `.byteLength` off
//             the object: C refused to compile (`no member named 'byteLength'`), JS took
//             the omitted branch for a provided object and threw on the missing one.
// Root cause: the resolver keeps nullable pointers as Union(Ref|Ptr|unknown, Null) — the
//             Maybe split leaves pointers unwrapped — and stringTruthiness lowered only
//             bare Ref conditions to a null-sentinel check, so the union shape fell
//             through every type-aware arm into the syntactic string fallback.
// Fix:        the null-sentinel arm also accepts what unwrapRefNullUnion collapses, so
//             `if (b)` lowers to the same `b !== null` the explicit check uses.

import { compileToC, compileToJS } from "../helpers";

class BugBox {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

interface BugTag {
	label: string;
}

class BugOuter {
	inner: BugBox | null;
	constructor(inner: BugBox | null) { this.inner = inner; }
}

function bugPick(props: { fb?: BugBox }): int32 {
	const b = props.fb;
	if (b) { return b.v; }
	return -1;
}

function bugLocal(b: BugBox | null): int32 {
	if (b) { return b.v; }
	return -1;
}

function bugIface(props: { tag?: BugTag }): string {
	const t = props.tag;
	if (t) { return t.label; }
	return "none";
}

function bugNested(o: BugOuter): int32 {
	const n = o.inner;
	if (n) { return n.v; }
	return -1;
}

function bugPickStr(props: { s?: string }): string {
	const s = props.s;
	if (s) { return s; }
	return "none";
}

test "bug222: provided and omitted optional class field" {
	assert bugPick({ fb: new BugBox(7) }) == 7, "provided";
	assert bugPick({}) == -1, "omitted";
}

test "bug222: nullable local parameter" {
	assert bugLocal(new BugBox(4)) == 4, "provided";
	assert bugLocal(null) == -1, "null";
}

test "bug222: optional interface field" {
	assert bugIface({ tag: { label: "tag" } }) == "tag", "provided";
	assert bugIface({}) == "none", "omitted";
}

test "bug222: nested nullable class field" {
	assert bugNested(new BugOuter(new BugBox(5))) == 5, "provided";
	assert bugNested(new BugOuter(null)) == -1, "null";
}

test "bug222: string truthiness neighbour keeps its length check" {
	assert bugPickStr({ s: "x" }) == "x", "provided";
	assert bugPickStr({}) == "none", "omitted";
}

test "bug222: C emits a null-sentinel check, not a string member read" {
	const c = compileToC("class OptBox { v: int32; constructor(v: int32) { this.v = v; } }\nfunction pick(props: { fb?: OptBox }): int32 { const b = props.fb; if (b) { return b.v; } return -1; }\nconsole.log(pick({ fb: new OptBox(7) }));\nconsole.log(pick({}));");
	assert c.ok, c.error;
	assert !c.value.contains("byteLength"), "condition must not read byteLength";
	assert c.value.contains("b_1_ != MS_NIL"), "condition must be a null-sentinel check";
}

test "bug222: JS emits b !== null" {
	const js = compileToJS("class OptBox { v: int32; constructor(v: int32) { this.v = v; } }\nfunction pick(props: { fb?: OptBox }): int32 { const b = props.fb; if (b) { return b.v; } return -1; }\nconsole.log(pick({ fb: new OptBox(7) }));\nconsole.log(pick({}));");
	assert js.ok, js.error;
	assert !js.value.contains("b.byteLength"), "condition must not read byteLength";
	assert js.value.contains("b !== null"), "condition must be a null-sentinel check";
}
