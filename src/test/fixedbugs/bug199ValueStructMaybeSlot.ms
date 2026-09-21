// bug199 — a value struct fits its own nullable slot
//
// Symptom:    `const v: V | null = makeV()` was rejected as `V` not assignable to `Maybe_V`.
// Root cause: the object-shape pre-check compared `V` with the generated Maybe carrier before fitting.
// Fix:        compare a non-Maybe value with the nullable slot's payload; fitNode then wraps it.

import { compileToC } from "../helpers";

const fromCall = `
struct V { n: float64; }
function makeV(): V { const v: V = { n: 1.5 }; return v; }
const v: V | null = makeV();
`;

const fromLiteral = `
struct V { n: float64; }
const v: V | null = { n: 1.5 };
`;

const wrongStruct = `
struct V { n: float64; }
struct W { name: string; }
function makeW(): W { const w: W = { name: "wrong" }; return w; }
const v: V | null = makeW();
`;

test "bug199: a returned value struct fits its nullable slot" {
	const c = compileToC(fromCall);
	assert c.ok, c.ok ? "" : c.error;
}

test "bug199: an object literal fits its value-struct nullable slot" {
	const c = compileToC(fromLiteral);
	assert c.ok, c.ok ? "" : c.error;
}

test "bug199: a different value struct remains rejected" {
	const c = compileToC(wrongStruct);
	assert !c.ok;
}
