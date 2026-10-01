// bug541 — an integer value narrowed or changed signedness without `as`
//
// Symptom:    `const b: uint32 = a` with `a: int32 = -1` printed 4294967295 in C and -1 in JS,
//             `t32(big)` with an int64 of 5000000000 failed at run time in C and wrapped in JS, and an
//             overload `ov(x: uint32)` took an int32 variable.
//
// Root cause: fitNode wrapped a narrowing integer in a silent conversion, relateCallArgs and the overload
//             relation (typeRelation's int widening by rank) admitted int32 → uint32.
//
// Fix:        an integer converts implicitly only to a type whose range holds every value of the source;
//             an integer literal that fits still converts, anything else needs `as`.

import { errorCount, hasError } from "../handoff/helpers";

test "bug541: a signed value into an unsigned declaration or assignment is refused" {
	assert hasError("const a: int32 = -1;\nconst b: uint32 = a;\n", "implicit int32 → uint32 conversion -1 is outside [0, 4294967295]");
	assert hasError("const a: int16 = -2;\nlet g: uint16 = 0;\ng = a;\n", "implicit int16 → uint16 conversion -2 is outside [0, 65535]");
}

test "bug541: an unsigned value into a wider signed slot widens implicitly" {
	assert errorCount("const u: uint8 = 3;\nconst i: int32 = u;\n") == 0;
}

test "bug541: a narrowing argument is refused" {
	assert hasError("function t32(x: int32): int32 { return x; }\nconst big: int64 = 5000000000 as int64;\nconst r = t32(big);\n",
		"implicit int64 → int32 conversion in 't32' arg 0 5000000000 is outside [-2147483648, 2147483647]");
	assert hasError("function tu8(x: uint8): uint8 { return x; }\nconst n: int32 = -1;\nconst r = tu8(n);\n",
		"implicit int32 → uint8 conversion in 'tu8' arg 0 -1 is outside [0, 255]");
}

test "bug541: an overload does not take an integer of the other signedness" {
	assert hasError("function ov(x: uint32): string { return \"u\"; }\nfunction ov(x: string): string { return x; }\nconst n: int32 = -7;\nconst s = ov(n);\n",
		"No matching overload for 'ov'");
}

test "bug541: same-signedness widening, fitting literals and explicit conversions stay accepted" {
	assert errorCount("function t32(x: int32): int32 { return x; }\nfunction ov(x: uint32): string { return \"u\"; }\nfunction ov(x: string): string { return x; }\n"
		+ "const a: int8 = -3;\nconst b: int32 = a;\nconst c: uint8 = 200;\nconst d: uint32 = c;\nconst e: int8 = -1;\n"
		+ "const w: int64 = 3 as int64;\nconst r = t32(w as int32) + t32(-5);\nconst s = ov(4) + ov(b as uint32);\n") == 0;
}
