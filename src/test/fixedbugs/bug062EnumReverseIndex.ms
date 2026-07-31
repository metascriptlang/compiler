// bug062 — enum reverse index E[v] + toString on a field-type-only enum
//
// Symptom:    fmt/roundtrip.ms (G1-gate): `NodeKind[node.kind]` reached C as
//             a literal `NodeKind[...]` index expression → clang "unexpected
//             type name 'NodeKind': expected expression". And
//             `d.declKind.toString()` on an enum reached only through an
//             imported field's type emitted a call to `DeclKind_toString`
//             that no TU defined → "call to undeclared function".
//
// Root cause: (a) The checker had no rule for an ArrayAccess whose base is an
//             enum TYPE symbol (TS numeric-enum reverse mapping) — it fell
//             through to getElementType(enum) = unknown, silently, and
//             codegen emitted the source form verbatim.
//             (b) Enum_toString definitions were injected per module by
//             walking the module scope for Enum symbols. An enum reachable
//             only via an imported field's type is not in module scope, so
//             call-site lowering (builtinLower/debugLower) emitted calls
//             with no definition in the TU.
//
// Fix:        Checker types `E[v]` as string (numeric or enum operand
//             required, fail-loud otherwise). builtinLower lowers it to
//             `E_toString(v)`. All lowering sites record the enum Type in
//             checkerCtx.pendingEnumToStrings; lowerEnumToString (moved to
//             the end of transformForNative) injects definitions for
//             scope-walk enums ∪ requested, deduped. Definitions are static
//             per-TU, so cross-module duplication is safe.

import { Item, makeItem } from "./bug062helper";

enum Shade { Dark, Light }

test "enum reverse index on enum-typed operand" {
	const s: Shade = Shade.Light;
	assert Shade[s] === "Light";
	assert Shade[Shade.Dark] === "Dark";
}

test "enum reverse index on int32 operand" {
	const i: int32 = 1;
	assert Shade[i] === "Light";
}

test "enum reverse index out of range" {
	const i: int32 = 9;
	assert Shade[i] === "<unknown>";
}

test "toString on enum reached only through an imported field type" {
	const it: Item = makeItem();
	assert it.grade.toString() === "Good";
}
