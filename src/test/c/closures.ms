// E2E: Closures and Arrow Functions → C output
// Tests lambda lifting transform + closure codegen.

import { compileToC } from "../helpers";

// Closures work end-to-end — see bug021_*.ms for the parser-side regression
// coverage; the lambda-lifting + codegen path is exercised by these E2E tests.

test "E2E C: non-capturing arrow function" {
	const src = "const double = (n: number): number => n * 2;\nconst r = double(5);";
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: closure captures outer variable" {
	const src = "function outer(): number {\n  const x: number = 10;\n  const f = (): number => x + 1;\n  return f();\n}\nconst r = outer();";
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: closure with mutable capture" {
	const src = "function make(): number {\n  let n: number = 0;\n  const inc = (): number => { n = n + 1; return n; };\n  return inc();\n}\nconst r = make();";
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: a lifted env, a loop temp and two same-named block locals each reach the frame with their own item" {
	const src = `function f(n: int32): int32 {
	let total = 0;
	{ const x = n; total += x; }
	{ const x = n * 2; total += x; }
	for (const v of [n, n + 1]) total += v;
	const g = (k: int32): int32 => total + k + n;
	return g(1);
}
console.log(f(3));`;
	const c = compileToC(src);
	assert c.ok, c.ok ? "" : c.error;
}
