// bug540 — an integer literal filled an enum slot
//
// Symptom:    `const c: Color = 1`, `{ c: 2 }` into a Color field and `d = 0` passed the checker, so a
//             literal outside the enum's members reached an exhaustive match.
//
// Root cause: fitNode kept an arm that retyped an integer literal to the enum of its slot.
//
// Fix:        the arm is gone; an enum slot takes a member of its enum, and an ordinal becomes an enum
//             only through `as`, as the reference's typeRel tyEnum relates only the same enum.

import { errorCount, hasError } from "../handoff/helpers";

const COLOR540 = "enum Color540 { Red, Green, Blue }\ninterface H540 { c: Color540; }\nfunction name540(c: Color540): int32 { return c as int32; }\n";

test "bug540: an integer literal is refused by an enum declaration" {
	assert hasError(COLOR540 + "const c: Color540 = 1;\n", "Type 'int32' is not assignable to type 'Color540'");
}

test "bug540: an integer literal is refused by an enum field and an enum assignment" {
	assert hasError(COLOR540 + "const h: H540 = { c: 2 };\n", "Type 'int32' is not assignable to type 'Color540'");
	assert hasError(COLOR540 + "let d: Color540 = Color540.Red;\nd = 0;\n", "Type 'int32' is not assignable to type 'Color540'");
}

test "bug540: an integer literal argument is refused for an enum parameter" {
	assert hasError(COLOR540 + "const n = name540(2);\n", "Argument type mismatch in 'name540' arg 0: got int32, expected Color540");
}

test "bug540: a member and an explicit conversion fill the enum slot" {
	assert errorCount(COLOR540 + "const h: H540 = { c: Color540.Blue };\nconst e: Color540 = 1 as Color540;\nconst n = name540(e) + name540(h.c);\n") == 0;
}
