// anonOptionalField — `field?: T` in ANONYMOUS object-type annotations.
//
// The anon-object string parse (resolvePass) took everything before the colon
// as the field name, so `fallback?: string` registered a field literally named
// "fallback?" — member reads missed ("Available: when, fallback?"), object
// literals failed the excess-key check ("'fallback' does not exist in type ''"),
// and the C anon struct had no member `fallback` (neon flow Show/For fallback).
// The interface TOKEN path already consumes and discards the `?` token
// (parseInterfaceLikeDecl); this aligns the string path with it.

class AofBox {
	v: number;
	constructor(v: number) { this.v = v; }
}

function aofPick(props: { when: boolean; fallback?: string }): string {
	const fb = props.fallback;
	if (fb) { return fb; }
	return "none";
}

function aofPickRef(props: { tag: number; fb?: AofBox }): number {
	const b = props.fb;
	if (b) { return b.v; }
	return -1;
}

test "anon optional value field: provided and omitted" {
	assert aofPick({ when: true, fallback: "f" }) == "f", "provided";
	assert aofPick({ when: true }) == "none", "omitted";
}

test "anon optional ref field: omitted is null-sentinel" {
	assert aofPickRef({ tag: 1, fb: new AofBox(7) }) == 7, "provided";
	assert aofPickRef({ tag: 1 }) == -1, "omitted";
}
