// E2E: Result<T, E> → JS output
// Tests Result type through JS backend pipeline.

import { compileToJS } from "../helpers";


test "E2E JS: Result.ok constructor" {
	const src = "function f(): Result<number, string> { return Result.ok(42); }\nconst r = f();";
	const js = compileToJS(src);
	assert js.ok;
}

test "E2E JS: Result.err constructor" {
	const src = "function f(): Result<number, string> { return Result.err(\"bad\"); }\nconst r = f();";
	const js = compileToJS(src);
	assert js.ok;
}

test "E2E JS: try operator unwrap" {
	const src = "function inner(): Result<number, string> { return Result.ok(10); }\nfunction outer(): Result<number, string> { const x = try inner(); return Result.ok(x + 1); }\nconst r = outer();";
	const js = compileToJS(src);
	assert js.ok;
}

test "E2E JS: try with catch fallback" {
	const src = "function maybe(): Result<number, string> { return Result.err(\"no\"); }\nfunction f(): number { const x = try maybe() catch 0; return x; }\nconst r = f();";
	const js = compileToJS(src);
	assert js.ok;
}
