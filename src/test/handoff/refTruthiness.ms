// refTruthiness — `if (x)` on a REF-typed value (class/interface) is a
// null-sentinel check, not the string byteLength fallback.
//
// wrapTruthiness (stringTruthiness.ms) had type-aware arms for boolean/Maybe/
// value-struct/array but NO Ref arm — a ref-typed bare identifier/member fell
// into the syntactic string fallback and emitted C `->byteLength` on a
// non-string struct (neon flow Show: `if (fb)` on a VNode interface value).
// Negation (`if (!x)`) was never affected: UnaryExpr is isAlreadyBoolean and
// C `!ptr` is valid — only the POSITIVE bare form hit the fallback.

interface RtVN {
	tag: string;
}

class RtBox {
	v: number;
	constructor(v: number) { this.v = v; }
}

function rtMk(tag: string): RtVN {
	return { tag: tag };
}

function rtIfaceLocal(): string {
	const v: RtVN = rtMk("li");
	if (v) { return v.tag; }
	return "none";
}

function rtClassParam(b: RtBox): number {
	if (b) { return b.v; }
	return -1;
}

function rtIfaceField(props: { when: boolean; fb: RtVN }): string {
	const f = props.fb;
	if (f) { return f.tag; }
	return "none";
}

test "bare interface local truthiness is a null check" {
	assert rtIfaceLocal() === "li", "iface local";
}

test "class param truthiness is a null check" {
	assert rtClassParam(new RtBox(7)) === 7, "class param";
}

test "interface field read from anon props truthiness" {
	assert rtIfaceField({ when: true, fb: rtMk("span") }) === "span", "iface field";
}
