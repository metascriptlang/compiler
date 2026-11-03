// `@wasm` marks an exported function for wasm placement on a js build; the functions it calls follow it.

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgram } from "../../checker/checkPass";
import { hasErrors } from "../../checker/context";
import { Node, ProgramData } from "../../ast/node";
import {
	wasmFunctionNames,
	withoutWasmFunctions,
} from "../../compiler/wasmBoundary/placement";

function parsed(src: string): Node {
	const pr = parseSource(src);
	if (!pr.ok) throw new Error(
		`internal: test source failed to parse: ${pr.error}`,
	);
	return pr.value;
}

function checked(src: string): Node {
	const program = parsed(src);
	const ctx = checkProgram(program);
	if (hasErrors(ctx)) throw new Error(
		`internal: test source failed to check: ${ctx.errors[0].message}`,
	);
	return program;
}

function checkErrorText(src: string): string {
	const ctx = checkProgram(parsed(src));
	if (!hasErrors(ctx)) return "";
	return ctx.errors[0].message;
}

test "@wasm on exported functions checks clean and names only those functions" {
	const src =
		"@wasm\nexport function f(): int32 { return g() + 1; }\nexport function g(): int32 { return 1; }\n@wasm\nexport function h(x: int32): int32 { return x; }\n";
	assert checkErrorText(src) == "";
	const names = wasmFunctionNames(checked(src));
	assert names.length == 2;
	assert names[0] == "f";
	assert names[1] == "h";
	assert wasmFunctionNames(parsed("export function f(): int32 { return 1; }\n"))
		.length == 0;
	const stripped = withoutWasmFunctions(checked(src));
	assert (stripped.data as ProgramData).programStmts.length == 1;
}

test "the module-level @wasm(); form is an error that points at function marking" {
	assert checkErrorText(
		"@wasm();\nexport function f(): int32 { return 1; }\n",
	).contains("@wasm marks a function, not a module");
}

test "@wasm is refused with an argument, off an export, inside a function and on a class method" {
	assert checkErrorText(
		'@wasm("x")\nexport function f(): int32 { return 1; }\n',
	).contains("@wasm takes no arguments");
	assert checkErrorText("@wasm\nfunction f(): int32 { return 1; }\n").contains(
		"@wasm applies to an exported module-level function",
	);
	assert checkErrorText(
		"export function outer(): int32 {\n\t@wasm\n\tfunction f(): int32 { return 1; }\n\treturn f();\n}\n",
	).contains("@wasm applies to an exported module-level function");
	assert checkErrorText(
		"export class C {\n\t@wasm\n\tget(): int32 { return 1; }\n}\n",
	).contains("a class method cannot be placed in wasm yet");
}

test "a wasm-placed function that stores its callback is refused, one that calls it is not" {
	const stored = checkErrorText(
		"let saved: ((x: int32) => int32) | null = null;\n@wasm\nexport function keep(cb: (x: int32) => int32): int32 { saved = cb; return 0; }\n",
	);
	assert stored.contains(
		"wasm-placed function 'keep' keeps its callback parameter 'cb': it stores it in 'saved'",
	);
	assert checkErrorText(
		"@wasm\nexport function use(cb: (x: int32) => int32): int32 { return cb(2) + 1; }\n",
	) == "";
	assert checkErrorText(
		"let saved: ((x: int32) => int32) | null = null;\nexport function keep(cb: (x: int32) => int32): int32 { saved = cb; return 0; }\n",
	) == "";
}

test "a wasm-placed function that keeps its callback through a helper is refused" {
	const src =
		"const all: ((x: int32) => int32)[] = [];\nfunction remember(f: (x: int32) => int32): void { all.push(f); }\n@wasm\nexport function keep(cb: (x: int32) => int32): int32 { remember(cb); return 0; }\n";
	assert checkErrorText(src).contains(
		"wasm-placed function 'keep' keeps its callback parameter 'cb': it passes it to 'remember'",
	);
}

test "module state that only wasm-placed code uses lives in wasm, directly or through a helper" {
	assert checkErrorText(
		"let count = 0;\n@wasm\nexport function bump(): int32 { count += 1; return count; }\n",
	) == "";
	assert checkErrorText(
		"const cells: int32[] = [];\nfunction add(v: int32): void { cells.push(v); }\n@wasm\nexport function push(v: int32): int32 { add(v); return cells.length; }\n@wasm\nexport function size(): int32 { return cells.length; }\n",
	) == "";
}

test "module state that JS-side code also uses is refused, at the JS-side use" {
	const fromFn = checkErrorText(
		"let count = 0;\n@wasm\nexport function bump(): int32 { count += 1; return count; }\nexport function peek(): int32 { return count; }\n",
	);
	assert fromFn.contains(
		"the module variable 'count' is used by wasm-placed function 'bump' and also by 'peek' at 4:",
	);
	const fromTop = checkErrorText(
		"let count = 0;\nfunction read(): int32 { return count; }\n@wasm\nexport function peek(): int32 { return read(); }\ncount = 5;\n",
	);
	assert fromTop.contains(
		"is used by wasm-placed function 'peek' through 'read' and also by top-level code at 5:",
	);
	const helper = checkErrorText(
		"let count = 0;\nfunction tick(): void { count += 1; }\n@wasm\nexport function bump(): void { tick(); }\nexport function jsTick(): void { tick(); }\n",
	);
	assert helper.contains(
		"'tick' uses module state that only wasm-placed code may use, and 'jsTick' at 5:",
	);
	const exportedHelper = checkErrorText(
		"let count = 0;\nexport function tick(): void { count += 1; }\n@wasm\nexport function bump(): void { tick(); }\n",
	);
	assert exportedHelper.contains(
		"'tick' uses module state that only wasm-placed code may use, and it is exported",
	);
	const exportedVar = checkErrorText(
		"export let count = 0;\n@wasm\nexport function bump(): int32 { count += 1; return count; }\n",
	);
	assert exportedVar.contains("uses the module variable 'count' at 3:");
	assert exportedVar.contains("which is exported");
}

test "const values and unrelated module state stay usable on both sides" {
	assert checkErrorText(
		'const LIMIT = 10;\nconst NAME = "x";\n@wasm\nexport function cap(n: int32): int32 { return n > LIMIT ? LIMIT : n + NAME.length; }\nexport function jsCap(): int32 { return LIMIT; }\n',
	) == "";
	assert checkErrorText(
		"let count = 0;\nexport function bump(): int32 { count += 1; return count; }\n@wasm\nexport function twice(n: int32): int32 { return n * 2; }\n",
	) == "";
}

const HANDLE_SRC = `
@builtin("FfiHandle")
export struct Handle<T> { ptr: Ptr<void>; }
export function value<T>(this h: Handle<T>): T { return h.ptr as T; }
export function retain<T>(this h: Handle<T>): void {}
export class Counter { n: int32 = 0; }
`;

function lentError(body: string): string {
	return checkErrorText(
		HANDLE_SRC +
			`@wasm\nexport function keep(h: Handle<Counter>): int32 { ${body} }\n`,
	);
}

test "a lent Handle parameter is only read through value()" {
	const lent =
		"Handle<Counter> parameter h is lent for the call: use it only as h.value()";
	assert lentError("return h.value().n;") == "";
	assert lentError("const c = h.value(); return c.n;") == "";
	assert lentError("const g = h; return g.value().n;").contains(lent);
	assert lentError("h.retain(); return 0;").contains(lent);
	assert lentError("const f = (): int32 => h.value().n; return f();").contains(
		lent,
	);
}

const VIEW_SRC = `
@builtin("FfiHandle")
export struct Handle<T> { ptr: Ptr<void>; }
@builtin("FfiVecBox")
export class VecBox<T> { items: Vec<T> = []; }
export function view<T>(this h: Handle<VecBox<T>>, f: (v: Span<T>) => void): void {}
let kept: Span<int32> | null = null;
function stash(v: Span<int32>): void { kept = v; }
`;

function viewError(body: string): string {
	return checkErrorText(
		VIEW_SRC +
			`export function run(h: Handle<VecBox<int32>>): void { ${body} }\n`,
	);
}

test "a view callback may index and set its Span but not keep it" {
	const ok = viewError("h.view((v: Span<int32>): void => { v[0] = v[1]; });");
	assert ok == "", ok;
	const escapes = "Span v escapes its view";
	assert viewError("h.view((v: Span<int32>): void => { kept = v; });").contains(escapes);
	assert viewError("h.view(stash);").contains("Span v escapes its view");
}
