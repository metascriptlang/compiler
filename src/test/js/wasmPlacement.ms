// `@wasm();` marks a module for wasm placement on a js build; it is a module directive, never a decorator.

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgram } from "../../checker/checkPass";
import { hasErrors } from "../../checker/context";
import { Node } from "../../ast/node";
import { hasWasmPlacement, placedModules } from "../../compiler/wasmBoundary/placement";
import { compileToCWithStd } from "../helpers";

function parsed(src: string): Node {
	const pr = parseSource(src);
	if (!pr.ok) throw new Error(`internal: test source failed to parse: ${pr.error}`);
	return pr.value;
}

function checkErrorText(src: string): string {
	const ctx = checkProgram(parsed(src));
	if (!hasErrors(ctx)) return "";
	return ctx.errors[0].message;
}

test "a module-level @wasm(); checks clean and marks its module" {
	const marked = "@wasm();\nexport function f(): int32 { return 1; }\n";
	assert checkErrorText(marked) == "";
	assert hasWasmPlacement(parsed(marked));
	assert !hasWasmPlacement(parsed("export function f(): int32 { return 1; }\n"));
}

test "the placed set is the marked modules, in load order" {
	const a = parsed("export const a = 1;");
	const b = parsed("@wasm();\nexport const b = 2;");
	const c = parsed("@wasm();\nexport const c = 3;");
	const placed = placedModules(["a.ms", "b.ms", "c.ms"], [a, b, c]);
	assert placed.length == 2;
	assert placed[0] == "b.ms";
	assert placed[1] == "c.ms";
	assert placedModules(["a.ms"], [a]).length == 0;
}

test "@wasm() with an argument is an error naming the directive" {
	const text = checkErrorText("@wasm(\"x\");\nexport const b = 2;");
	assert text.contains("@wasm() takes no arguments");
}

test "@wasm() on a function stays refused" {
	const c = compileToCWithStd("@wasm()\nexport function f(): int32 { return 1; }\nconsole.log(f());\n");
	assert !c.ok;
	if (!c.ok) assert c.error.contains("Decorators are not valid here");
}
