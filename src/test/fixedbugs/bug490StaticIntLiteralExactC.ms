// bug490 — a static field's integer initializer lost precision on C
//
// Symptom:    `static big: int64 = 9007199254740993` printed 9007199254740992 on C, and
//             `static top: uint64 = 18446744073709551615` did not compile (`18446744073709552000`
//             is too large for any C integer type); JS printed both exactly.
// Root cause: genStaticFieldGlobals spelled the literal from its float64 value (formatCNumber)
//             instead of its exact integer value.
// Fix:        it spells the literal with formatCNumberLit, as every other literal site does.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

const K = "export class K {\n\tstatic big: int64 = 9007199254740993;\n\tstatic top: uint64 = 18446744073709551615;\n\tstatic neg: int32 = -5;\n\tstatic f: float64 = 0.5;\n}\nexport function read(): string { return K.big.toString() + K.top.toString() + K.neg.toString() + K.f.toString(); }\n";

test "bug490: an int64 static initializer keeps its last digit" {
	const c = cOf(K);
	assert c.contains(" = 9007199254740993LL;");
	assert !c.contains("9007199254740992");
}

test "bug490: a uint64 static initializer is spelled as an unsigned literal" {
	const c = cOf(K);
	assert c.contains(" = 18446744073709551615ULL;");
	assert !c.contains("18446744073709552000");
}

test "bug490: int32 and float64 static initializers keep their spelling" {
	const c = cOf(K);
	assert c.contains(" = -5;");
	assert c.contains(" = 0.5;");
}
