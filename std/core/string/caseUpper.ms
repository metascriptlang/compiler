// One case direction in a module of its own, so the C compiler specializes the shared kernel for this
// direction instead of testing it at each code point (toUpperCase on mixed text was 1.08-1.14x the C kernel without it).

import { upperRuns, upperFull } from "./caseTables";
import { caseLength, caseInto } from "./caseCore";

export function upperLength(s: Readonly<Span<uint8>>): int64 {
	return caseLength(s, upperRuns, upperFull, false);
}

export function upperInto(s: Readonly<Span<uint8>>, out: Span<uint8>): void {
	caseInto(s, out, upperRuns, upperFull, false);
}
