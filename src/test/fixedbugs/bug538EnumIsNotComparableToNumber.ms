// bug538 — `==` accepted an enum against any number
//
// Symptom:    `color == 2` and `2 != color` passed the checker for `enum Color`, comparing the ordinal
//             with an integer the enum does not declare.
//
// Root cause: equalityOperandsOk accepted any numeric operand beside an enum.
//
// Fix:        `==` takes an enum only with its own enum, as the reference's `==`[Enum: enum](x, y: Enum);
//             the ordinal is compared through an explicit `as int32`.

import { errorCount, hasError } from "../handoff/helpers";

const COLOR538 = "enum Color538 { Red, Green, Blue }\n";

test "bug538: an enum compared with an integer literal is refused" {
	assert hasError(COLOR538 + "function f(c: Color538): boolean { return c == 2; }\n", "operator '==' cannot be applied to types 'Color538' and 'int32'");
}

test "bug538: an integer variable compared with an enum is refused on either side" {
	assert hasError(COLOR538 + "function f(c: Color538, n: int64): boolean { return n != c; }\n", "operator '!=' cannot be applied to types 'int64' and 'Color538'");
}

test "bug538: the ordinal compares through an explicit conversion" {
	assert errorCount(COLOR538 + "function f(c: Color538): boolean { return (c as int32) == 2 || c == Color538.Blue; }\n") == 0;
}
