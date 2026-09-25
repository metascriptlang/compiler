// bug520 — a declaration, an assignment and an array element took values a call argument refuses
//
// Symptom:    `const k: int32 = "abc"`, `j = s` with `s: string`, `const b: boolean = 3`, a function of
//             another signature, `Result<int32, E>` into `Result<string, E>`, bigint into number and a
//             string into a literal union all passed the checker. C then failed in clang or called a
//             closure through the wrong ABI; JS printed the wrong value.
//
// Root cause: fitNode returned early for every same-kind pair and ended without a relation for the
//             rest, so only the layout gate (`isReinterpretUnsafe`) ever refused a value there.
//
// Fix:        fitNode ends like the reference's (sem.nim fitNode → typeMismatch): a pair that is neither
//             assignable nor an implicit conversion is an error at every slot. Only the nullable class
//             (`T | null` into `T`, `null` into a reference) stays open, pending its sites.

import { hasError } from "../handoff/helpers";
import { compileToC, compileToJS } from "../helpers";

test "bug520: a string into an int32 declaration is refused" {
	assert hasError("const k: int32 = \"abc\";\n", "Type 'string' is not assignable to type 'int32'");
}

test "bug520: a string assigned to an int32 variable is refused" {
	assert hasError("function f(s: string): void { let j: int32 = 0; j = s; }\n", "Type 'string' is not assignable to type 'int32'");
}

test "bug520: an int32 into a boolean and a boolean into a string are refused" {
	assert hasError("const a: boolean = 3;\n", "Type 'int32' is not assignable to type 'boolean'");
	assert hasError("const s: string = true;\n", "Type 'boolean' is not assignable to type 'string'");
}

test "bug520: a function of another signature is refused at declaration, assignment and element" {
	const pre = "const a: (x: int32) => int32 = (x: int32): int32 => x + 1;\n";
	assert hasError(pre + "const b: (x: string) => int32 = a;\n", "Type 'function' is not assignable to type 'function'");
	assert hasError(pre + "let c: (x: string) => int32 = (s: string): int32 => 0;\nc = a;\n", "Type 'function' is not assignable to type 'function'");
	assert hasError(pre + "const fs: ((x: string) => int32)[] = [a];\n", "Type 'function' is not assignable to type 'function'");
}

test "bug520: a Result of another ok type is refused at a declaration" {
	assert hasError("function mk(): Result<int32, string> { return Result.ok(5); }\nconst s: Result<string, string> = mk();\n", "Type 'Result' is not assignable to type 'Result'");
}

test "bug520: bigint and number do not convert implicitly" {
	assert hasError("function f(b: bigint): void { const c: number = b; }\n", "Type 'bigint' is not assignable to type 'number'");
	assert hasError("function f(n: number): void { const d: bigint = n; }\n", "Type 'number' is not assignable to type 'bigint'");
}

test "bug520: a string into a literal union is refused" {
	assert hasError("type Dir = \"north\" | \"south\";\nfunction f(s: string): void { const d: Dir = s; }\n", "Type 'string' is not assignable to type '\"north\" | \"south\"'");
}

test "bug520: a generic body instantiated with string refuses the int32 slot" {
	assert hasError("function viaFn<T>(v: T): int32 { const k: int32 = v; return k; }\nconst r = viaFn<string>(\"a\");\n", "Type 'string' is not assignable to type 'int32'");
}

test "bug520: the JS backend refuses the same declaration" {
	const r = compileToJS("function f(s: string): void { const k: int32 = s; }\n");
	assert !r.ok;
}

test "bug520: widening, void lambdas, a ternary under a cast and a ternary into a rest parameter stay accepted" {
	const src = "class A520 { n: int32; constructor(n: int32) { this.n = n; } }\n"
		+ "class B520 extends A520 { constructor(n: int32) { super(n); } }\n"
		+ "function pick(c: boolean, a: A520, b: A520): B520 { return (c ? a : b) as B520; }\n"
		+ "function eff(f: () => void): void { f(); }\n"
		+ "function run(c: boolean): void {\n"
		+ "\tconst i: int32 = 7;\n\tconst w: int64 = i;\n\tconst f: float64 = i;\n\tconst u8: uint8 = 200;\n"
		+ "\tlet x: int32 | string = 5;\n\tx = \"a\";\n"
		+ "\teff(() => i + 1);\n"
		+ "\tconsole.log(c ? \"yes\" : \"no\");\n"
		+ "}\n";
	const r = compileToC(src);
	assert r.ok, r.error;
}

test "bug520: a literal for a generic interface inside a generic class body stays accepted" {
	assert !hasError("interface Op520<T> { v: T; }\ninterface Q520<T> { ops: Op520<T>[]; reset: boolean; }\n"
		+ "class H520<T> {\n\tattach(): Q520<T> {\n\t\tconst q: Q520<T> = { ops: [], reset: false };\n\t\treturn q;\n\t}\n}\n",
		"is not assignable");
}
