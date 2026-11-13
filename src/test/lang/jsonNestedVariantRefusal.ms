// A field of a tagged struct that is a union but not a tagged struct of struct variants
// is refused at JSON.parse expansion, naming the field, instead of being decoded as tagged.
//
// Symptom:    a nested tagged struct field was rejected as "nullable"; widening that fix to
//             every non-null union would have decoded `string | int32` as if tagged.
// Root cause: the nested-struct read is only meant for a struct or a union of struct variants.
// Fix:        the field read takes a union only when every member is a struct variant.

import { hasError } from "../handoff/helpers";

const PRELUDE = "enum K { A, B } ";

test "a string or int32 field is refused naming the field" {
	assert hasError(PRELUDE + "struct R = match (kind: K) { K.A => { value: string | int32 }, K.B => {} }; function f(t: string): void { JSON.parse<R>(t); }", "field 'value'");
}

test "a struct or string field is refused naming the field" {
	assert hasError(PRELUDE + "struct P { x: int32 } struct R = match (kind: K) { K.A => { value: P | string }, K.B => {} }; function f(t: string): void { JSON.parse<R>(t); }", "field 'value'");
}
