// bug555 — a folded integer constant expression was refused where its literal fits
//
// Symptom:    `export const BASE: uint64 = 1 << 3;` failed with "implicit int32 → uint64 conversion changes
//             signedness", so the solana guard fixture did not check on any host; `8` in the same slot passed.
//
// Root cause: the same-signedness rule (Q3) exempted only a literal or a negated literal; the reference folds
//             the constant expression first and fits the folded literal.
//
// Fix:        isFittingIntLiteral folds an expression built only from untyped integer literals and consts with
//             constantLiteralOf and fits the result, range checked; a typed const keeps its type.

import { errorCount } from "../handoff/helpers";

test "bug555: a folded constant expression fits a slot its value fits" {
	assert errorCount("export const BASE: uint64 = 1 << 3;\n") == 0;
	assert errorCount("const K = 5;\nconst U: uint32 = K * 2 + 1;\n") == 0;
	assert errorCount("const M: uint8 = (1 << 7) | 1;\n") == 0;
}

test "bug555: a folded constant expression outside the slot's range stays refused" {
	assert errorCount("const N: uint64 = 0 - 1;\n") == 1;
	assert errorCount("const B: uint8 = 1 << 9;\n") == 1;
}

test "bug555: an expression over a typed const keeps the const's type" {
	assert errorCount("const k: int32 = 5;\nconst U: uint32 = k * 2;\n") == 1;
	assert errorCount("const u: uint8 = 3;\nconst I: int32 = u + 1;\n") == 0;
}
