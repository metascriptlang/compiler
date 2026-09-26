// @stdout: refs 7 -1 4 -1 5 -1 tags tag none str x none
// note: `if (b)` on a nullable reference is sugar for `b !== null` — the
// null-sentinel arm of stringTruthiness also accepts the Union(Ref, Null)
// shape the resolver keeps for nullable pointers. Before the fix the
// condition read `b.byteLength`: C refused to compile, JS took the omitted
// branch for a provided object and threw on the missing one.

class OptBox {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

interface OptTag {
	label: string;
}

class OptOuter {
	inner: OptBox | null;
	constructor(inner: OptBox | null) { this.inner = inner; }
}

function pick(props: { fb?: OptBox }): int32 {
	const b = props.fb;
	if (b) { return b.v; }
	return -1;
}

function local(b: OptBox | null): int32 {
	if (b) { return b.v; }
	return -1;
}

function nested(o: OptOuter): int32 {
	const n = o.inner;
	if (n) { return n.v; }
	return -1;
}

function tagOf(props: { tag?: OptTag }): string {
	const t = props.tag;
	if (t) { return t.label; }
	return "none";
}

function strOf(props: { s?: string }): string {
	const s = props.s;
	if (s) { return s; }
	return "none";
}

console.log(`refs ${pick({ fb: new OptBox(7) })} ${pick({})} ${local(new OptBox(4))} ${local(null)} ${nested(new OptOuter(new OptBox(5)))} ${nested(new OptOuter(null))} tags ${tagOf({ tag: { label: "tag" } })} ${tagOf({})} str ${strOf({ s: "x" })} ${strOf({})}`);
