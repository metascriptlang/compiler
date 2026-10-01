// bug574 — explicit type arguments on a static generic never reached the arguments
//
// Symptom:    `Result.ok<string, string>(5)` passed the checker and failed in clang;
//             `Result.ok<Entry, string>(tag)` handed the variant pointer to a union slot in C
//             (pinned at run time by corpus 253 and 258).
// Root cause: inferGenericReturnWithExplicit substituted the return type and returned without
//             fitting the arguments against the instantiated formals.
// Fix:        with the bindings final, every argument is checked and fitted against its bound
//             formal (reference: an explicit instantiation matches arguments against the instance).

import { compileToC } from "../helpers";

test "bug574: an argument against an explicit type argument is checked" {
	const r = compileToC("const r = Result.ok<string, string>(5);");
	assert !r.ok;
	if (!r.ok) {
		assert r.error.contains("got int32, expected string");
	}
}
