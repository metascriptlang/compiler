// bug091 — a TS-style union discriminated by enum members was not a DU
//
// Symptom:    `type Ev = ClickEv | KeyEv` with `kind: EvKind.Click` /
//             `kind: EvKind.Key` failed to even construct: the object literal
//             stayed an anonymous struct, so C rejected the assignment
//             ("assigning to 'Ev' from incompatible type"). JSON encode/decode
//             of such a union was unreachable for the same reason.
// Root cause: resolvePass auto-stamps the discriminator contract (typeExtra =
//             disc type, typeNames = [disc, keys...]) for boolean-discriminated
//             TS-style unions only. The enum case — the shape the match-type DU
//             form already supports — was never wired, so `isDiscriminatedUnion`
//             was false and every downstream consumer treated it as a plain union.
// Fix:        src/checker/types.ms grew `findSharedEnumDiscriminant` on the
//             existing kind-parameterized literal-discriminant machinery (plus a
//             kind-aware literal-value read: an EnumLiteral keeps its value in
//             typeNames[0], not typeName), and resolvePass stamps the enum case
//             next to the boolean one.

enum B91EvKind { Click, Key }
interface B91ClickEv { kind: B91EvKind.Click; x: int32; }
interface B91KeyEv { kind: B91EvKind.Key; code: int32; }
type B91Ev = B91ClickEv | B91KeyEv;

test "bug091: enum-discriminated TS-style union constructs" {
	const e: B91Ev = { kind: B91EvKind.Click, x: 7 };
	assert JSON.stringify(e).includes("Click");
}

test "bug091: JSON round-trips an enum-discriminated TS-style union" {
	const e: B91Ev = { kind: B91EvKind.Key, code: 42 };
	const r = JSON.parse<B91Ev>(JSON.stringify(e));
	assert r.ok;
}

test "bug091: JSON rejects an unknown enum discriminator" {
	const r = JSON.parse<B91Ev>(`{"kind":"Wheel","delta":1}`);
	assert !r.ok;
}
