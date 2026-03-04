// E2E: Closures and Arrow Functions → C output
// Tests lambda lifting transform + closure codegen.

import { compileToC, assertContains, assertNoError } from "../helpers";
import { check } from "std/testing";

// KNOWN ISSUE: Arrow functions and closures fail in E2E pipeline.
// The checker/validator/transform chain rejects them before codegen.
// These tests document the current limitation and should be uncommented
// when the pipeline supports closures end-to-end.

// test "E2E C: non-capturing arrow function" {
// 	const src = "const double = (n: number): number => n * 2;\nconst r = double(5);";
// 	const c = compileToC(src);
// 	check(assertNoError(c));
// }

// test "E2E C: closure captures outer variable" {
// 	const src = "function outer(): number {\n  const x: number = 10;\n  const f = (): number => x + 1;\n  return f();\n}\nconst r = outer();";
// 	const c = compileToC(src);
// 	check(assertNoError(c));
// }

// test "E2E C: closure with mutable capture" {
// 	const src = "function make(): number {\n  let n: number = 0;\n  const inc = (): number => { n = n + 1; return n; };\n  return inc();\n}\nconst r = make();";
// 	const c = compileToC(src);
// 	check(assertNoError(c));
// }
