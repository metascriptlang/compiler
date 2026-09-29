// bug615 — a narrowing cast to a type alias skipped its JS conversion
//
// Symptom:    `type Byte = uint8; wide(300) as Byte` printed 300 on JS and 44 on C;
//             `wide(300) as uint8` printed 44 on both.
// Root cause: the JS conversion passes (intConvJS, bigIntJS) and the C range
//             check's untyped fallback chose the conversion from the cast's
//             annotation text, and an alias name matched no integer kind.
// Fix:        every cast pass reads the checked target type of the cast.

import { compileToJS } from "../helpers";

type Byte = uint8;
function wide(n: int32): int32 { return n; }

test "bug615: a narrowing cast to an alias wraps on C" {
	const b = wide(300) as Byte;
	assert b == 44;
}

test "bug615: a narrowing cast to an alias masks on JS" {
	const r = compileToJS("type Byte = uint8;\nfunction f(v: int32): Byte { return v as Byte; }\nconsole.log(f(300));\n");
	assert r.ok;
	if (r.ok) { assert r.value.contains("& 255"); }
}
