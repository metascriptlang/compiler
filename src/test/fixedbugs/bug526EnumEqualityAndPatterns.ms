// bug526 — equality accepted an enum against anything and a match took another enum's members
//
// Symptom:    `match (c)` over `Color` with `Other.Red` / `Other.Green` / `Other.Blue` arms passed as
//             exhaustive and matched by ordinal; `c == Other.Red`, `case Other.Red:`, `c == "Red"` and
//             `a == b` for two unrelated structs passed the checker (clang then refused the last two).
//
// Root cause: equalityOperandsOk accepted any pair with an enum on one side and any two structs, and
//             checkMatchExpr counted a pattern as covering the member of the same property name
//             without relating the pattern to the discriminant.
//
// Fix:        `==` relates two enums only when they are the same enum (the reference's
//             `==`[Enum: enum](x, y: Enum)), two structs only
//             when one is assignable to the other; each match value pattern is checked against the
//             discriminant (the reference's semCaseBranch fitNode) and only a fitting one covers a
//             member.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

const ENUMS526 = "enum Color { Red, Green, Blue }\nenum Other { Blue, Green, Red }\n";

test "bug526: a match arm of another enum is refused" {
	assert hasError(ENUMS526 + "function f(c: Color): int32 { return match (c) { Other.Red => 1, Other.Green => 2, Other.Blue => 3 }; }\n", "case of type 'Other' is not comparable to the switch value of type 'Color'");
}

test "bug526: a switch case of another enum is refused" {
	assert hasError(ENUMS526 + "function f(c: Color): int32 { switch (c) { case Other.Red: return 1; default: return 0; } }\n", "case of type 'Other' is not comparable to the switch value of type 'Color'");
}

test "bug526: comparing two enums or an enum and a string is refused" {
	assert hasError(ENUMS526 + "function f(c: Color): boolean { return c == Other.Red; }\n", "operator '==' cannot be applied to types 'Color' and 'Other'");
	assert hasError(ENUMS526 + "function f(c: Color): boolean { return c == \"Red\"; }\n", "operator '==' cannot be applied to types 'Color' and 'string'");
}

test "bug526: comparing two unrelated structs is refused" {
	assert hasError("struct A526 { x: int32; }\nstruct B526 { y: string; }\nfunction f(a: A526, b: B526): boolean { return a == b; }\n", "operator '==' cannot be applied to types 'A526' and 'B526'");
}

test "bug526: the same enum, an enum and a number, and an exhaustive match stay accepted" {
	const r = compileToC(ENUMS526 + "function f(c: Color): int32 { return match (c) { Color.Red => 1, Color.Green => 2, Color.Blue => 3 }; }\n"
		+ "function g(c: Color): boolean { return c == Color.Green || (c as int32) == 2; }\n"
		+ "struct P526 { x: int32; }\nfunction h(a: P526, b: P526): boolean { return a == b; }\n");
	assert r.ok, r.error;
}
