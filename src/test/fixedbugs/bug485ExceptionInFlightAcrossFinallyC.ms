// bug485 — an exception in flight was lost when its finally raised and handled another one
//
// Symptom:    `try { boom("first"); } finally { try { boom("second"); } catch { } }` under an
//             outer `catch (e)` panicked on C (member access within null pointer) reading
//             `e.message`; JS printed "first". A finally that raised a new exception leaked the
//             one it replaced, and a `return` / `break` inside a finally leaked the exception it
//             swallowed.
// Root cause: the finally section saved and cleared only `msErr`; the single exception slot
//             `msCurrException` was overwritten by the raise inside the finally and nulled by
//             its handler, so the restored `msErr` propagated a NULL exception.
// Fix:        the finally section also moves the slot into `__oldExc_N` and restores it after
//             the body; a raise out of the body goes through `__finraise_N`, which releases the
//             held exception, and a jump out of the body releases it in blockLeaveActions.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function occurrences(hay: string, needle: string): int32 {
	return (hay.split(needle).length - 1) as int32;
}

function lastFunction(c: string): string {
	return c.slice(c.lastIndexOf(" f__"), c.byteLength);
}

const BOOM = "export function boom(m: string): void { throw new Error(m); }\n";

test "bug485: the finally section holds the exception in flight and restores it" {
	const c = cOf(BOOM + "export function f(): void {\n\ttry { boom(\"a\"); } finally { try { boom(\"b\"); } catch { } }\n}\n");
	assert c.contains("__oldExc_1 = msCurrException;"), lastFunction(c);
	assert c.contains("msCurrException = __oldExc_1;"), lastFunction(c);
}

test "bug485: a raise out of the finally body releases the exception it replaces" {
	const c = cOf(BOOM + "export function f(): void {\n\ttry { boom(\"a\"); } finally { boom(\"b\"); }\n}\n");
	assert c.contains("if (msErr) goto __finraise_1;"), lastFunction(c);
	assert c.contains("msDecref((void*)__oldExc_1);"), lastFunction(c);
}

test "bug485: a return inside the finally body releases the exception it swallows" {
	const c = cOf(BOOM + "export function f(): int32 {\n\ttry { boom(\"a\"); } finally { return 5; }\n\treturn 0;\n}\n");
	assert occurrences(c, "msDecref((void*)__oldExc_1);") == 2, lastFunction(c);
}
