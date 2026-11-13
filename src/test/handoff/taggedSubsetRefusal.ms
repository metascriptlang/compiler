// A narrowed subset of a tagged union meets the union as an explicit generic argument; a variant of another union does not

import { hasError } from "./helpers";

const REPLIES = "enum K { A, B, C }\nstruct R = match (kind: K) { K.A => { x: int32 }, K.B => { y: int32 }, K.C => { z: int32 } };\n"
	+ "enum J { P, Q }\nstruct O = match (kind: J) { J.P => { p: int32 }, J.Q => { q: int32 } };\n";

test "a narrowed subset of its own union is accepted as a generic argument" {
	assert !hasError(REPLIES + "function f(r: R): Result<R, string> { if (r.kind == K.C) { return Result.err(\"c\"); } return Result.ok<R, string>(r); }", "Argument type mismatch");
}

test "a variant of another tagged struct is refused as a generic argument" {
	assert hasError(REPLIES + "function f(o: O): Result<R, string> { return Result.ok<R, string>(o); }", "Argument type mismatch in 'ok' arg 0");
}
