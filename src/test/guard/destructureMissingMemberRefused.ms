// A destructured name must be a stored field of a settled source, or the declaration is refused
//
// INVARIANT: `const { k } = src` over a primitive, a union with no such field, or a type whose `k` is an
//   extension is refused at the declaration; the binding never stays an Inferred type that reaches codegen.
//
// WHAT IT CATCHES: the missing-field check skipping a source that is not a plain struct, and the extension
//   exemption accepting the name without typing it, so a call through the binding failed in C and JS.
//
// RED MEANS: one of the shapes compiled. The same pattern over a stored field still binds.
//
// GUARD-CHECK-FAIL Property 'missing' does not exist on type
// GUARD-CHECK-FAIL cannot destructure 'area'
// GUARD-CHECK-FAIL cannot destructure 'kind'
// GUARD-JS

interface GuardLeft { kind: "left"; x: int32; }
interface GuardRight { kind: "right"; y: int32; }
interface GuardShape { value: int32; }
function area(this s: GuardShape): int32 { return s.value; }
function make(left: boolean): GuardLeft | GuardRight {
	if (left) return { kind: "left", x: 1 };
	return { kind: "right", y: 2 };
}
const prim: int32 = 1;
const shape: GuardShape = { value: 7 };
const uni = make(true);
const { value } = shape;
const { missing: fromPrim } = prim; // GUARD-REFUSED
const { missing: fromUnion } = uni; // GUARD-REFUSED
const { kind } = uni; // GUARD-REFUSED
const { area: measure } = shape; // GUARD-REFUSED
console.log(value, kind, fromPrim, fromUnion, measure());
