// bug096 — an inline-cast witness (`null as T | null`) lost its type in the
// macro round-trip, breaking nested-struct JSON decode
//
// Symptom:    `jsonValueToStructE(v, null as Employee | null, errs, "")` on a
//             type with a NESTED struct field died in the checker: "Property
//             'addr' does not exist on type 'null'". Flat structs passed,
//             which masked the bug.
// Root cause: the macro round-trip dropped the witness type at three joints:
//             checkJsxConsumed re-checked an already-typed macro arg and
//             collapsed the witness to bare null; valueToNode lacked the
//             TypeObject/Array/Generic/Function type-AST arms; nodeToValue
//             lacked the nodeTypeAst fallback that nodeToASTLiteral had.
//             Typed AST must not be re-semmed — the arg carries nodeTypeAst.

import { jsonValueToStructE, parseJson } from "std/serialize/json";

interface B96Address { city: string; zip: int32; }
interface B96Employee { name: string; addr: B96Address; }

test "inline-cast witness decodes a nested struct" {
	const pr = parseJson(`{"name":"a","addr":{"city":"HN","zip":100}}`);
	assert pr.ok;
	const errs: string[] = [];
	const v: B96Employee = jsonValueToStructE(pr.value, null as B96Employee | null, errs, "");
	assert errs.length === 0;
	assert v.addr.city === "HN";
	assert v.addr.zip === 100;
}

test "JSON.parse facade decodes the same nested struct" {
	const r = JSON.parse<B96Employee>(`{"name":"b","addr":{"city":"SG","zip":700}}`);
	assert r.ok;
	if (r.ok) {
		assert r.value.addr.zip === 700;
	}
}
