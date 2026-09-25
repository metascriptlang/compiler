// bug483 — a field named stdout, errno, EOF or NAN broke the C build
//
// Symptom:    `interface RunResult { stdout: string; stderr: string; }` failed to compile on C
//             (`expected parameter declarator`); errno gave `field '_errno' declared as a
//             function`, NAN `field '__builtin_nanf' declared as a function`. JS ran.
// Root cause: field names escaped only C keywords; the standard headers define these names
//             as macros, so the preprocessor rewrote the declaration and every access.
// Fix:        field names and parameter names also escape the standard-header macro names.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

test "bug483: stdio stream macro names are escaped as fields" {
	const c = cOf("export interface R { code: int32; stdout: string; stderr: string; stdin: int32; }\nexport function f(r: R): string { return r.stdout; }\n");
	assert c.contains("stdout_0;");
	assert c.contains("stderr_0;");
	assert c.contains("stdin_0;");
	assert c.contains(".stdout_0");
}

test "bug483: errno, EOF, NAN, INFINITY, assert and offsetof are escaped as fields" {
	const c = cOf("export interface M { errno: int32; EOF: int32; NAN: int32; INFINITY: int32; assert: int32; offsetof: int32; }\nexport function f(m: M): int32 { return m.errno + m.offsetof; }\n");
	assert c.contains("errno_0;");
	assert c.contains("EOF_0;");
	assert c.contains("NAN_0;");
	assert c.contains("INFINITY_0;");
	assert c.contains("assert_0;");
	assert c.contains("offsetof_0;");
}

test "bug483: a parameter named after a standard-header macro is escaped" {
	const c = cOf("export function f(errno: int32, EOF: int32): int32 { return errno + EOF; }\n");
	assert c.contains("(errno_ + EOF_)");
}
