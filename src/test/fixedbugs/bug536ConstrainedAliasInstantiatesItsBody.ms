// bug536 — a generic alias with a constrained parameter instantiated its body under the constraint's spelling
//
// Symptom:    `type Box<T extends number> = { value: T }; const b: Box<int32> = { value: 42 };` was refused
//             ("Type '__anon1__valuei' is not assignable to type 'Box'") once slots relate their payload.
//
// Root cause: instantiateGenericBody substituted the declared parameter list as spelled by the parser,
//             "T:number", so no field named `T` was replaced and the instance body kept the bare parameter.
//
// Fix:        the instance body substitutes the parameter name without its `:constraint` suffix, as
//             defineGenericParam already splits it.

import { errorCount, hasError } from "../handoff/helpers";

test "bug536: a constrained alias instance accepts a literal of its substituted shape" {
	assert errorCount("type Box536<T extends number> = { value: T };\nconst b: Box536<int32> = { value: 42 };\n") == 0;
}

test "bug536: a second, unconstrained parameter substitutes beside a constrained one" {
	assert errorCount("type Pair536<K extends string, V> = { k: K; v: V };\nconst p: Pair536<string, int32> = { k: \"a\", v: 3 };\n") == 0;
}

test "bug536: the substituted body still refuses a field of another type" {
	assert hasError("type Box536<T extends number> = { value: T };\nconst b: Box536<int32> = { value: \"x\" };\n", "is not assignable");
}
