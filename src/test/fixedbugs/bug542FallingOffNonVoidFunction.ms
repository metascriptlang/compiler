// bug542 — a function with a non-void return type could fall off the end of its body
//
// Symptom:    `function num(flag: boolean): int32 { if (flag) { return 5; } }` passed the checker;
//             `num(false)` returned 0 in C and undefined in JS, and a class return type read a NULL
//             object.
//
// Root cause: nothing checked that the end of a body is unreachable when the return type needs a
//             value; C codegen appended a zero return and JS returned undefined.
//
// Fix:        after checking a body, a reachable end is an error for every non-void return type
//             (TypeScript 2366, 2534 for never); the binder keeps the flow node at the end of the body,
//             a constant-false branch and a call that returns never end the path.

import { errorCount, hasError } from "../handoff/helpers";

const LACKS542 = "lacks an ending return statement";

test "bug542: a named function that falls off on one path is refused" {
	assert hasError("function num(flag: boolean): int32 {\n\tif (flag) { return 5; }\n}\n", "'num' " + LACKS542 + ": its return type 'int32'");
	assert hasError("class Foo542 { x: int32 = 7; }\nfunction pick(flag: boolean): Foo542 {\n\tif (flag) { return new Foo542(); }\n}\n", "'pick' " + LACKS542);
	assert hasError("function maybe(flag: boolean): string | null {\n\tif (flag) return \"a\";\n}\n", "'maybe' " + LACKS542 + ": its return type 'string | null'");
}

test "bug542: a method, an async function, a switch and a loop that fall off are refused" {
	assert hasError("class W542 { run(flag: boolean): string { if (flag) { return \"a\"; } } }\n", "'run' " + LACKS542);
	assert hasError("async function ag(flag: boolean): Promise<int32> { if (flag) { return 1; } }\n", "'ag' " + LACKS542 + ": its return type 'int32'");
	assert hasError("function sw(k: int32): string { switch (k) { case 1: return \"a\"; } }\n", "'sw' " + LACKS542);
	assert hasError("function lp(n: int32): int32 { for (let i = 0; i < n; i++) { if (i == 3) return i; } }\n", "'lp' " + LACKS542);
}

test "bug542: an arrow that falls off is refused whether its return type is written, contextual or inferred" {
	assert hasError("const a = (flag: boolean): int32 => { if (flag) { return 1; } };\n", LACKS542 + ": its return type 'int32'");
	assert hasError("function takeCb(cb: (n: int32) => boolean): boolean { return cb(1); }\nconst r = takeCb((n) => { if (n > 0) { return true; } });\n", LACKS542 + ": its return type 'boolean'");
	assert hasError("const inferred = (flag: boolean) => { if (flag) { return 1; } };\n", LACKS542);
}

test "bug542: a never function whose end is reachable is refused" {
	assert hasError("function nv(flag: boolean): never { if (flag) { throw new Error(\"x\"); } }\n", "'nv' returns 'never' but can reach the end of its body");
}

test "bug542: a body whose every path returns, throws or never returns stays accepted" {
	assert errorCount("function fail(msg: string): never { throw new Error(msg); }\n"
		+ "function a(flag: boolean): int32 { if (flag) { return 1; } else { return 2; } }\n"
		+ "function b(flag: boolean): int32 { while (true) { if (flag) return 1; } }\n"
		+ "function c(flag: boolean): int32 { if (flag) return 1; throw new Error(\"x\"); }\n"
		+ "function d(flag: boolean): int32 { if (flag) return 1; fail(\"no\"); }\n"
		+ "function e(k: int32): string { switch (k) { case 1: return \"a\"; default: return \"b\"; } }\n"
		+ "function m(k: int32): int32 { match (k) { 1 => { return 1; }, _ => { return 2; } } }\n"
		+ "function f(flag: boolean): void { if (flag) { return; } }\n"
		+ "function h(flag: boolean): int32 | void { if (flag) return 1; }\n"
		+ "async function g(flag: boolean): Promise<void> { if (flag) return; }\n"
		+ "function nv(): never { while (true) { } }\n"
		+ "const ok = (flag: boolean) => { if (flag) { return 1; } return 2; };\n") == 0;
}
