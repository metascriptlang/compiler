// bug012 — cross-module generic with value-type T omitted enum/distinct injection
//
// Symptom:    Calling a generic helper from a different module with T = enum
//             or type-alias triggered a C compile error:
//                 "assigning to 'ColorArray' from incompatible type 'msRefArray'"
//             Hit by SERIALIZE V2 decode wiring — `_jsonToIntArray<Color>` (in
//             prelude `std/core/json/index.cms`) and any user-defined helper
//             `<T>(witness: T | null): T[]` in a separate `.ms` file both
//             failed when T was a value-typed user type (enum, type alias).
//
//             The mangled function signature was correct
//             (`ColorArray _jsonToIntArray__Color(...)`) but the body's local
//             variable `const out: T[] = []` emitted as untyped `msRefArray`
//             after monomorphization, breaking the `out = ...` assignment site.
//
// Root cause: `injectConcreteTypeSyms` in `src/checker/instantiate.ms`
//             enumerates handled type kinds (Ref/Array/Struct/GenericInstance)
//             when injecting the concrete type symbols into the body scope
//             before re-checking. Enum and Distinct (type-alias) cases were
//             missing — Color/UserId never got added to the body's scope, so
//             `resolveAnnotation("Color[]")` during the body re-check
//             couldn't find `Color`, fell back to `Unknown`, and the array
//             type collapsed to the untyped `msRefArray` runtime container.
//
// Fix:        Add `TypeKind.Enum` and `TypeKind.Distinct` cases to
//             `injectConcreteTypeSyms`, both calling `tryInjectTypeSym` with
//             the type's `typeName` — same shape as the existing Struct case.

import { compileToC } from "../helpers";

test "bug012: cross-module generic with enum T compiles" {
	const src = `
enum Color { Red, Green, Blue }

function makeArr<T>(witness: T | null): T[] {
	const out: T[] = [];
	return out;
}

function main(): void {
	const w: Color | null = null;
	const arr: Color[] = makeArr<Color>(w);
	const _len = arr.length;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug012: cross-module generic with type-alias T compiles" {
	const src = `
type UserId = int32;

function makeArr<T>(witness: T | null): T[] {
	const out: T[] = [];
	return out;
}

function main(): void {
	const w: UserId | null = null;
	const arr: UserId[] = makeArr<UserId>(w);
	const _len = arr.length;
}
`;
	const c = compileToC(src);
	assert c.ok;
}
