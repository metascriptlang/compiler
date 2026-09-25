// bug523 — any integer value converted implicitly to an enum
//
// Symptom:    `name(n)` with `n: int32 = 42` and `const c: Color = n` passed the checker; the
//             exhaustive `match` over Color then fell off its end (C: no return value, JS:
//             `undefined`).
//
// Root cause: isAssignable carried an Integer → Enum arm, so every slot took an integer as an enum.
//
// Fix:        the arm is gone, as in the reference's typeRel tyEnum (only the same enum relates). An
//             integer LITERAL still fits an enum slot at a declaration, assignment or field.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

const COLOR523 = "enum Color { Red, Green, Blue }\nfunction name(c: Color): int32 { return 1; }\n";

test "bug523: an int32 argument is refused for an enum parameter" {
	assert hasError(COLOR523 + "const n: int32 = 42;\nconst s = name(n);\n", "Argument type mismatch in 'name' arg 0: got int32, expected Color");
}

test "bug523: an int32 value is refused by an enum declaration" {
	assert hasError(COLOR523 + "const n: int32 = 42;\nconst c: Color = n;\n", "Type 'int32' is not assignable to type 'Color'");
}

test "bug523: an int64 value is refused by an enum field" {
	assert hasError(COLOR523 + "interface H523 { c: Color; }\nconst n: int64 = 1;\nconst h: H523 = { c: n };\n", "is not assignable to type 'Color'");
}

test "bug523: an enum member and an integer literal field stay accepted" {
	const r = compileToC(COLOR523 + "interface H523 { c: Color; }\nconst c: Color = Color.Green;\nconst h: H523 = { c: 0 };\nconst s = name(c);\n");
	assert r.ok, r.error;
}
