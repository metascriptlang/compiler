// bug029 — Bridge fallback masks literal types as Identifier(name=value)
//
// Symptom:    `JSON.stringify(c)` where `c: Circle = {kind: "circle", r: 5}`
//             failed C compile with "operand of type 'msString' where
//             arithmetic or pointer type is required" — codegen tried to
//             cast `kind` (msString) to int64. Same for CBOR.
//
// Root cause: src/compiler/meta/bridge.ms mapTypeToAstWith didn't handle
//             TypeKind.StringLiteral / TypeKind.BooleanLiteral explicitly —
//             they fell through to fallbackTypeName → atomicTypeNode →
//             Identifier(name = literal_value). Encode struct path saw
//             Identifier with tn="circle"/"true"/"false", missed the atomic
//             match (string/boolean/number/...), landed in the jsonInt /
//             cborInt fallback with a bad widening cast.
//
// Fix:        Bridge emits StringLiteral / BooleanLiteral nodes for literal
//             types so encode/decode/discDetect can distinguish a literal
//             value from a regular type-name Identifier.
//
// Touched:    src/compiler/meta/bridge.ms          (mapTypeToAstWith)
//             std/serialize/json/encode.ms          (StringLiteral/BooleanLiteral routing)
//             std/serialize/json/decode.ms          (emit literal value directly)
//             std/serialize/cbor/encode.ms          (mirror JSON fix)
//             std/serialize/cbor/decode.ms          (mirror JSON fix)
//             std/serialize/discDetect.ms           (extractVariantKey reads .value/.boolValue)

// CBOR equivalent tests live in src/test/c/json.ms (compileToC E2E).

interface Circle { kind: "circle"; r: int32; }
interface OkBag { ok: true; val: int32; }

test "bug029: JSON literal-string disc field encodes correctly" {
	const c: Circle = { kind: "circle", r: 5 };
	const json = JSON.stringify(c);
	assert json === "{\"kind\":\"circle\",\"r\":5}";
}

test "bug029: JSON literal-bool disc field encodes correctly" {
	const o: OkBag = { ok: true, val: 42 };
	const json = JSON.stringify(o);
	assert json === "{\"ok\":true,\"val\":42}";
}

