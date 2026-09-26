// bug545 — a switch case whose body completes into the next case was accepted and its fall-through dropped
//
// Symptom:    `case 1: r = r + "one;"; case 2: r = r + "two;"; break;` returned "one;" for 1 on C and
//             JS, where TypeScript runs both bodies.
//
// Root cause: switchLower drops the terminal break and emits each case alone; nothing refused a
//             non-empty case that can reach the next one.
//
// Fix:        a non-empty case other than the last whose end is reachable is refused (TypeScript's
//             noFallthroughCasesInSwitch, TS7029); Nim's case has no fall-through. The binder keeps
//             the flow node at the end of each case, the same reachability the missing-return check
//             reads.

import { errorCount, hasError } from "../handoff/helpers";

const FALLS545 = "switch case falls through into the next case";

test "bug545: an integer case that completes into the next case is refused" {
	assert hasError("function ints(n: int32): string {\n\tlet r = \"\";\n\tswitch (n) {\n\t\tcase 1:\n\t\t\tr = r + \"one;\";\n\t\tcase 2:\n\t\t\tr = r + \"two;\";\n\t\t\tbreak;\n\t\tdefault:\n\t\t\tr = r + \"d;\";\n\t}\n\treturn r;\n}\n", FALLS545);
}

test "bug545: a string case whose if has one open branch is refused" {
	assert hasError("function strs(s: string, f: boolean): int32 {\n\tlet r: int32 = 0;\n\tswitch (s) {\n\t\tcase \"a\":\n\t\t\tif (f) { break; }\n\t\t\tr = 1;\n\t\tcase \"b\":\n\t\t\tr = 2;\n\t\t\tbreak;\n\t}\n\treturn r;\n}\n", FALLS545);
}

test "bug545: stacked labels, closed cases and an open last case stay accepted" {
	assert errorCount("function ok(n: int32, f: boolean): int32 {\n\tlet r: int32 = 0;\n\tswitch (n) {\n\t\tcase 1:\n\t\tcase 2:\n\t\t\tr = 2;\n\t\t\tbreak;\n\t\tcase 3:\n\t\t\tif (f) { return 1; } else { return 2; }\n\t\tcase 4:\n\t\t\tthrow new Error(\"four\");\n\t\tdefault:\n\t\t\tr = 9;\n\t}\n\treturn r;\n}\n") == 0;
}
