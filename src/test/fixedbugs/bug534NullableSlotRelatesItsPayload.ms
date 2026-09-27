// bug534 — a value reaching a nullable value slot was wrapped without being related to the payload
//
// Symptom:    `const n: int32 | null = "seven"` and `function pick(): string | null { return 3; }`
//             passed the checker (clang then failed, JS printed `seven`), and so did a named function of
//             another signature into a nullable closure slot; the same argument to a parameter was refused.
//
// Root cause: fitNode's `T -> T | null` arm checked only a nominal mismatch before synthMaybeWrap, so the
//             payload never met the relation every other slot applies; and a literal met the wrapper, not
//             the payload, so `"row"` into `("row" | "column") | null` was typed `string`.
//
// Fix:        the arm refuses what the slot relation refuses for the payload, and a literal is typed
//             against the payload of a nullable slot, as TypeScript types it against the non-null member
//             of its contextual type.

import { errorCount, hasError } from "../handoff/helpers";

test "bug534: a nullable value slot refuses a value of another type" {
	assert hasError("const n: int32 | null = \"seven\";\n", "Type 'string' is not assignable to type 'int32 | null'");
}

test "bug534: a nullable return refuses a value of another type" {
	assert hasError("function pick(): string | null { return 3; }\n", "Type 'int32' is not assignable to type 'string | null'");
}

test "bug534: a nullable closure declaration refuses a function of another signature" {
	assert hasError("function named(s: string, flag: boolean): string { return s; }\n"
		+ "const f: ((s: string, i: number) => string) | null = named;\n", "is not assignable");
}

test "bug534: a nullable closure return refuses an arrow of another signature" {
	assert hasError("function pick(): ((s: string, i: number) => string) | null { return (s: string, flag: boolean): string => s; }\n", "is not assignable");
}

test "bug534: a literal is typed against the payload of a nullable slot" {
	assert errorCount("type FD534 = \"row\" | \"column\";\n"
		+ "type S534 = { fd: FD534 | null; w: float32 | null; on: boolean | null; b: int8 | null };\n"
		+ "const x: S534 = { fd: \"row\", w: 3, on: true, b: 5 };\n"
		+ "x.fd = \"column\";\n"
		+ "function pick(): FD534 | null { return \"row\"; }\n") == 0;
	assert hasError("function big(): int8 | null { return 300; }\n", "cannot convert 300 to int8");
}

test "bug534: a matching payload and null still fill the nullable slot" {
	assert errorCount("function named(s: string, i: number): string { return s; }\n"
		+ "const f: ((s: string, i: number) => string) | null = named;\n"
		+ "const g: ((s: string, i: number) => string) | null = null;\n"
		+ "const n: int32 | null = 7;\n"
		+ "const w: int64 | null = n ?? 0;\n") == 0;
}
