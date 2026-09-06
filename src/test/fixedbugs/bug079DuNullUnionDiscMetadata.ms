// bug079 — `DU | null` dropped the match-type's disc metadata
//
// Symptom:    jsonValueToStructE(jv, null as Event | null, ...) on an
//             enum-disc match-type DU failed to expand: "cannot determine
//             discriminator for union type". A bare `null as Event` worked.
// Root cause: createUnion (src/checker/types.ms) flattens
//             Union(Event(V1,V2), Null) into [V1,V2,Null] via emptyType()
//             and never copied typeNames/typeExtra, so the bridge's
//             unionToAst handed macros a union with no
//             discFieldName/discKind/variantKeys. Match-type variants carry
//             no disc field, so auto-detect cannot recover (string-disc DUs
//             survived only through their literal `kind` fields).
// Fix:        createUnion propagates typeNames/typeExtra when the result is
//             a null-extension of exactly one metadata-bearing union with
//             variants index-aligned from 0.
//
// Runs the SOURCE checker via the macro expansion, so this file proves
// red/green without rebuilding the compiler.

import { jsonValueToStructE } from "std/serialize/json";

enum B79Kind { Alpha, Beta }

type B79Event = match (kind: B79Kind) {
	B79Kind.Alpha => { xv: number },
	B79Kind.Beta => { note: string },
};

test "bug079: enum-disc DU decodes through a `| null` witness" {
	const pr = parseJson(`{"kind":"Beta","note":"n"}`);
	assert pr.ok;
	const errs: string[] = [];
	const e: B79Event = jsonValueToStructE(pr.value, null as B79Event | null, errs, "");
	assert errs.length == 0;
	assert e.kind == B79Kind.Beta;
	if (e.kind == B79Kind.Beta) {
		assert e.note == "n";
	}
}
