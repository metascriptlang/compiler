// Parked at inbox card 2026-09-27-generic-ref-layout-identity.md
// Parked at inbox card 2026-10-03-std-generic-instance-takes-another-modules-same-named-type.md

import { fixtureShapeValue } from "./fixtures/sameNamedShape";

enum ReferenceKind { Ok, Err }

type ReferenceBody<T, E> = match (kind: ReferenceKind) {
	ReferenceKind.Ok => { value: T },
	ReferenceKind.Err => { error: E },
};

type VariantRef<T, E> = Ref<ReferenceBody<T, E>>;

function numericReference(value: float64): VariantRef<float64, string> { return { kind: ReferenceKind.Ok, value: value }; }

function textError(error: string): VariantRef<float64, string> { return { kind: ReferenceKind.Err, error: error }; }

function textReference(value: string): VariantRef<string, float64> { return { kind: ReferenceKind.Ok, value: value }; }

function numericError(error: float64): VariantRef<string, float64> { return { kind: ReferenceKind.Err, error: error }; }

test "nominalInstantiation: reference-wrapped generic variants retain the substituted payload in each arm" {
	const n = numericReference(99);
	const e = textError("boom");
	const s = textReference("hello-payload");
	const f = numericError(42);
	assert n.kind == ReferenceKind.Ok;
	assert e.kind == ReferenceKind.Err;
	assert s.kind == ReferenceKind.Ok;
	assert f.kind == ReferenceKind.Err;
	if (n.kind == ReferenceKind.Ok) assert n.value == 99;
	if (e.kind == ReferenceKind.Err) assert e.error == "boom";
	if (s.kind == ReferenceKind.Ok) assert s.value == "hello-payload";
	if (f.kind == ReferenceKind.Err) assert f.error == 42;
}

interface WireCircle { kind: "circle"; r: float64; }
interface WireSquare { kind: "square"; side: float64; }
type WireShape = WireCircle | WireSquare;

test "nominalInstantiation: a std generic instance keeps a type named like another module's type" {
	assert fixtureShapeValue() == 5;
	const parsed = JSON.parse<WireShape>(`{"kind":"square","side":3.0}`);
	assert parsed.ok;
	assert parsed.value.kind == "square";
}
