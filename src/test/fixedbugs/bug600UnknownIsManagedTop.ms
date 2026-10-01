// bug600 — unknown was an uncounted pointer, and what it may hold was never stated
//
// Symptom:    an object parked in `unknown` was never freed (or freed twice through a
//             container), arrays and maps entered `unknown` with no type-erased
//             destroy, a spawn thunk wrote through a captured `unknown`, an actor
//             field of type unknown crashed the build, and a C extern's rest args
//             reached the C function as one packed array.
// Root cause: `unknown` was a primitive kind (isPrimitiveKind), so every hook and
//             view skipped it; restParamLower packed an extern's varargs.
// Fix:        `unknown` is the managed top — a cyclic Ref released through the
//             header type — holding class and interface instances only; extern
//             rest arguments pass flat, like console.log.

import { hasError, strictErrorCount } from "../handoff/helpers";
import { compileToC } from "../helpers";

function accepts(src: string): boolean {
	return strictErrorCount(src) == 0;
}

const node = "class Node { name: string = \"n\"; }\n";

test "bug600: a class instance, an interface object and a generic instance enter unknown" {
	assert accepts(node + "interface I { v: int32; }\nclass Box<T> { v: T; constructor(v: T) { this.v = v; } }\n"
		+ "function f(): void { const a: unknown = new Node(); const b: unknown = { v: 1 } as I; const c: unknown = new Box<int32>(1); }");
}

test "bug600: an array does not enter unknown" {
	assert hasError("function f(): void { const xs: int32[] = [1]; const u: unknown = xs; }", "unknown holds class and interface instances");
}

test "bug600: a map does not enter unknown" {
	assert hasError("function f(): void { const m = new Map<string, int32>(); const u: unknown = m; }", "unknown holds class and interface instances");
}

test "bug600: an unknown argument reaches an actor only by move" {
	const src = node + "actor K { private kept: unknown = null; take(u: unknown): void { this.kept = u; } }\n"
		+ "function f(): void { const k = new K(); const u: unknown = new Node(); k.take(u); }";
	assert hasError(src, "actor methods only accept");
}

test "bug600: an actor holds an unknown field and takes one by move" {
	const src = node + "actor K { private kept: unknown = null; take(u: unknown): void { this.kept = u; } }\n"
		+ "function f(): void { const k = new K(); const u: unknown = new Node(); k.take(move u); }\nf();";
	assert compileToC(src).ok;
}

test "bug600: a spawn thunk cannot write through a captured unknown" {
	const src = node + "async function f(): Promise<void> {\n\tconst u: unknown = new Node();\n"
		+ "\tconst h = spawn(() => { (u as Node).name = \"x\"; return 1; });\n\tawait h;\n}";
	assert hasError(src, "Readonly<unknown>");
}

test "bug600: an extern's rest arguments reach C one by one" {
	const src = "extern function printf(fmt: cstring, ...args: unknown[]): int32;\n"
		+ "function f(c: cstring): void { printf(\"%s %d\", c, 5 as int32); }\nf(\"a\");";
	const r = compileToC(src);
	assert r.ok;
	assert r.value.contains("printf(");
	assert !r.value.contains("msGenericArrayPush");
}
