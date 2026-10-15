// Checker — a function literal with an unannotated parameter is typed after the arguments that bind its type parameter; a parameter nothing binds is refused at the call

import { strictErrorCount, hasError } from "./helpers";

const DECLS = "function twice<T>(f: (v: T) => T, x: T): T { return f(f(x)); }\n"
	+ "function effect<T>(compute: (prev: T | null) => T, run: (v: T) => void): void { run(compute(null)); }\n"
	+ "function seed<T>(f: (n: int32, prev: T | null) => T): T { return f(0, null); }\n"
	+ "function needsStr(s: string): string { return s; }\n";

test "an unannotated parameter ahead of the binding argument takes the bound type" {
	assert strictErrorCount(DECLS + "const a = twice(s => needsStr(s), \"x\");\nconst b: string = a;") == 0;
	assert hasError(DECLS + "const a = twice(n => needsStr(n), 1);", "got int32, expected string");
}

test "a literal that writes its types out binds before its unannotated parameters are typed" {
	assert strictErrorCount(DECLS + "effect(() => \"x\", (v) => { needsStr(v); });") == 0;
	assert strictErrorCount(DECLS + "effect((p: string | null) => \"x\", (v) => { needsStr(v); });") == 0;
	assert strictErrorCount(DECLS + "effect((p): string => \"x\", (v) => { needsStr(v); });") == 0;
}

test "a parameter whose type parameter no argument binds is refused" {
	assert hasError(DECLS + "effect((p) => \"x\", (v) => { needsStr(v); });", "cannot instantiate: 'T' — no argument binds it before parameter 'p'");
	assert hasError(DECLS + "const s = seed((n, prev) => \"x\");", "before parameter 'prev'");
	assert strictErrorCount(DECLS + "const s = seed((n) => \"x\");\nconst t: string = s;") == 0;
}
