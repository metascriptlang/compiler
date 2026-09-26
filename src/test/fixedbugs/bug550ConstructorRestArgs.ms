// bug550 — a constructor with a rest parameter refused every argument that fills it
//
// Symptom:    `new Summed(1, 2, 3)` against `constructor(base: number, ...rest: number[])` failed with
//             "Type 'int32' is not assignable to type '...number[]'"; a plain function with the same
//             rest parameter was accepted.
//
// Root cause: checkNewExpr fitted each argument to the formal at its index, so the argument at the
//             rest position met the rest array itself and later arguments met nothing; once every slot
//             refused a mismatch (bug520), the rest position became an error.
//
// Fix:        as the call path (relateCallArgs), an argument at or after the rest position fits the
//             rest element type, a spread argument the rest array.

import { errorCount, hasError } from "../handoff/helpers";

const CLS550 = "class Summed550 {\n\ttotal: number;\n\tconstructor(base: number, ...rest: number[]) {\n\t\tlet t = base;\n\t\tfor (const n of rest) { t = t + n; }\n\t\tthis.total = t;\n\t}\n}\nclass Ints550 {\n\ttotal: int32 = 0;\n\tconstructor(...xs: int32[]) { for (const x of xs) this.total += x; }\n}\n";

test "bug550: constructor rest arguments fit the rest element" {
	assert errorCount(CLS550 + "const a = new Summed550(1, 2, 3);\nconst b = new Ints550(1, 2, 3);\nconst c = new Ints550();\n") == 0;
}

test "bug550: a constructor rest argument of another element type is still refused" {
	assert hasError(CLS550 + "const d = new Ints550(1, \"two\");\n", "not assignable to type 'int32'");
}
