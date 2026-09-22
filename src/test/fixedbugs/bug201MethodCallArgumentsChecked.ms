// bug201 — a method-form call never checked its arguments
//
// Symptom:    `"x".extAt(pf)` with `pf: number` and `"x".extAt("s")` compiled, while `plainAt("x", pf)`
//             was refused; Raiser read the wrong byte and C died in clang.
// Root cause: a method-form call resolves through the pre-resolved extension branch or
//             `resolveExtensionOverloadCall`, and both returned before the argument loop plain calls run.
// Fix:        the argument loop is `relateCallArgs`, run by plain calls and by both method-form paths.

import { compileToC } from "../helpers";

const header = `
function extAt(this s: string, i: int32): int32 { return i; }
function plainAt(s: string, i: int32): int32 { return i; }
class C { at(i: int32): int32 { return i; } }
function pick(this s: string, i: int32): int32 { return i; }
function pick(this n: int32, i: int32): int32 { return i; }
const pf: number = 1.5;
const pi: int32 = 1;
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	return c.ok ? "" : c.error;
}

test "bug201: a plain call narrowing its argument is refused" {
	assert errorOf("plainAt(\"xy\", pf);").indexOf("narrowing") >= 0;
}

test "bug201: an extension call narrowing its argument is refused" {
	assert errorOf("\"xy\".extAt(pf);").indexOf("narrowing") >= 0;
}

test "bug201: an extension call with a mismatched argument is refused" {
	assert errorOf("\"xy\".extAt(\"s\");").indexOf("Argument type mismatch") >= 0;
}

test "bug201: a class method call narrowing its argument is refused" {
	assert errorOf("new C().at(pf);").indexOf("narrowing") >= 0;
}

test "bug201: an overloaded extension call narrowing its argument is refused" {
	assert errorOf("\"xy\".pick(pf);").indexOf("narrowing") >= 0;
}

test "bug201: method-form calls with matching arguments compile" {
	assert errorOf("\"xy\".extAt(pi); new C().at(pi); \"xy\".pick(pi); console.log(pf);") == "";
}
