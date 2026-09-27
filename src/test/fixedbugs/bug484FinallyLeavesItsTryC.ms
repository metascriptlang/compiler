// bug484 — a jump out of a try, or inside its finally, still counted that try as open on C
//
// Symptom:    `try { return 7; } catch { … } finally { flaky(); }` — a raise from the finally
//             inlined at the return jumped to the same try's catch, and the finally ran again;
//             a `return` / `break` / `continue` inside a finally body printed its lines twice
//             (`continue` looped once more). JS ran each finally once.
// Root cause: C codegen kept the finally bodies and the raise targets on two stacks.
//             blockLeaveActions popped only the finallys, so raise checks inside an inlined
//             finally read the target of the try being left; the finally section was generated
//             before its own entry was popped, so a jump inside it inlined it again.
// Fix:        one stack of (finally, raise label) per try, popped by blockLeaveActions and
//             before the finally section is generated.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function occurrences(hay: string, needle: string): int32 {
	return (hay.split(needle).length - 1) as int32;
}

function lastFunction(c: string): string {
	return c.slice(c.lastIndexOf("int32_t f"), c.byteLength);
}

const FLAKY = "let calls: int32 = 0;\nexport function flaky(): void { calls += 1; if (calls == 1) throw new Error(\"x\"); }\n";

test "bug484: a raise in a finally inlined at a return leaves the try" {
	const c = cOf(FLAKY + "export function f(): int32 {\n\ttry { return 7; } catch { return 8; } finally { flaky(); }\n\treturn 0;\n}\n");
	assert occurrences(c, "goto __catch_") == 1, lastFunction(c);
	assert occurrences(c, "goto __aftercatch_") == 0, lastFunction(c);
}

test "bug484: a raise in a finally inlined at a break leaves the try" {
	const c = cOf(FLAKY + "export function f(): int32 {\n\tlet n: int32 = 0;\n\twhile (n < 3) { n += 1; try { break; } finally { flaky(); } }\n\treturn n;\n}\n");
	assert occurrences(c, "goto __finally_") == 0, lastFunction(c);
}

test "bug484: a return inside a finally does not inline that finally again" {
	const c = cOf("export function f(k: int32): int32 {\n\tlet n: int32 = k;\n\ttry { n += 1; } finally { n += 12345; return n; }\n\treturn 0;\n}\n");
	assert occurrences(c, "12345") == 1, lastFunction(c);
}

test "bug484: a continue inside a finally does not inline that finally again" {
	const c = cOf("export function f(): int32 {\n\tlet n: int32 = 0;\n\tfor (let i: int32 = 0; i < 3; i += 1) { try { n += 1; } finally { n += 12345; continue; } }\n\treturn n;\n}\n");
	assert occurrences(c, "12345") == 1, lastFunction(c);
}
