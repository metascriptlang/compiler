// bug221 — `throw` accepted any operand while `catch` typed its binding a non-null `Error`
//
// Symptom:    `throw 7` panicked on C (the number became the exception pointer) and reached `catch`
//             raw on JS; `throw null` handed `catch` a null `Error`; `throw "x"` gave C an `Error`
//             carrying the message and JS the raw string (`e.message` undefined), and neither was an
//             `instanceof Error`. On C, throwing a string variable and reading it again afterwards
//             printed garbage and trapped (`log=[label 3,      !]`, exit 133). Neon's error
//             boundary lost a `throw null` inside an effect.
// Root cause: the checker checked the operand with no expected type, and each backend guessed what
//             to raise from the operand's shape.
// Fix:        as Nim `semRaise`, the operand must be an `Error`; a string operand is sugar the
//             checker rewrites into a checked `new Error(<string>)`, so every backend raises a
//             std `Error` through its existing `new Error` path. The comptime engine compiles a
//             class on demand, as it does a helper, so macros can construct that `Error`.

import { hasError, strictErrorCount } from "../handoff/helpers";
import { compileToC, compileToJS, compileToCWithStd } from "../helpers";

const REFUSED = "only an 'Error' or a 'string' can be thrown";

test "bug221: a number literal is refused" {
	assert hasError("function f(): void { throw 7; }", REFUSED + ", got 'int32'");
}

test "bug221: a number variable is refused" {
	assert hasError("function f(n: number): void { throw n; }", REFUSED + ", got 'number'");
}

test "bug221: null is refused" {
	assert hasError("function f(): void { throw null; }", REFUSED + ", got 'null'");
}

test "bug221: a nullable Error is refused before narrowing" {
	assert hasError("function f(x: Error | null): void { throw x; }", REFUSED);
}

test "bug221: unknown is refused" {
	assert hasError("function f(u: unknown): void { throw u; }", REFUSED + ", got 'unknown'");
}

test "bug221 control: an Error, a narrowed Error and a rethrow stay legal" {
	assert strictErrorCount("function f(): void { throw new Error(\"x\"); }") == 0;
	assert strictErrorCount("function f(x: Error | null): void { if (x !== null) { throw x; } }") == 0;
	assert strictErrorCount("function f(): void { try { f(); } catch (e) { throw e; } }") == 0;
}

test "bug221 control: string, string variable and template operands stay legal" {
	assert strictErrorCount("function f(): void { throw \"x\"; }") == 0;
	assert strictErrorCount("function f(s: string): void { throw s; }") == 0;
	assert strictErrorCount("function f(n: number): void { throw `n=${n}`; }") == 0;
}

test "bug221: C raises a thrown string as a std Error" {
	const c = compileToC("function f(): void { throw \"bare 7\"; }\ntry { f(); } catch (e) { const m = e.message; }");
	assert c.ok;
	assert !c.value.contains("msThrow(");
	assert c.value.contains("msCurrException = (msException*)(");
}

test "bug221: JS raises a thrown string as a std Error" {
	const js = compileToJS("function f(): void { throw \"bare 7\"; }\ntry { f(); } catch (e) { const m = e.message; }");
	assert js.ok;
	assert !js.value.contains("throw \"bare 7\"");
	assert js.value.contains("throw new Error");
}

test "bug221: number and null do not reach either backend" {
	assert !compileToC("function f(): void { throw 7; }").ok;
	assert !compileToJS("function f(): void { throw 7; }").ok;
	assert !compileToC("function f(): void { throw null; }").ok;
	assert !compileToJS("function f(): void { throw null; }").ok;
}

const MACRO_ERROR = `
import { Node, NodeKind } from "std/meta";

macro check(node: Node): Node {
	if (node.kind === NodeKind.StringLiteral) { error("a string is rejected", node); }
	return node;
}

const v: int32 = check("no");
`;

const MACRO_THROW = `
import { Node, NodeKind } from "std/meta";

macro check(node: Node): Node {
	if (node.kind === NodeKind.StringLiteral) { throw new Error("a string is rejected"); }
	return node;
}

const v: int32 = check("no");
`;

test "bug221: error() in a macro keeps its message" {
	const c = compileToCWithStd(MACRO_ERROR);
	assert !c.ok;
	assert c.error.contains("Macro 'check': a string is rejected"), c.error;
}

test "bug221: a macro can construct and throw an Error" {
	const c = compileToCWithStd(MACRO_THROW);
	assert !c.ok;
	assert c.error.contains("unhandled exception: a string is rejected"), c.error;
}
