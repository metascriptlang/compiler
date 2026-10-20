// Parked at inbox card 2026-10-15-std-generic-instance-takes-an-imported-modules-same-named-type.md

import { fixtureShapeValue } from "./fixtures/sameNamedShape";

interface WireCircle { kind: "circle"; r: float64; }
interface WireSquare { kind: "square"; side: float64; }
type WireShape = WireCircle | WireSquare;

test "nominalInstantiation: a std generic instance keeps a type named like another module's type" {
	assert fixtureShapeValue() == 5;
	const parsed = JSON.parse<WireShape>(`{"kind":"square","side":3.0}`);
	assert parsed.ok;
	assert parsed.value.kind == "square";
}
