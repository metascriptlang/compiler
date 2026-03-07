// E2E Test Helpers — full pipeline: MetaScript source → C/JS output
//
// Mirrors src/compiler/compile.ms:32-78 (cmdCompile).
// Used by cross-phase integration tests to catch regressions spanning phase boundaries.

import { parseSource } from "../parser/statements/validation";
import "../parser/statements/core";
import { checkProgram } from "../checker/checkPass";
import { hasErrors } from "../checker/context";
import { monomorphizeProgram } from "../monomorphize/collect";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { analyzeProgram } from "../analyzer/index";
import { generateCModule } from "../codegen/c/index";
import { createAliveSet } from "../codegen/c/context";
import { generateJS } from "../codegen/js/index";
import { sliceStr } from "../utils/string";

type CompileResult = Result<string, string>;

function collectErrors(errors: any[], prefix: string): string {
	let msg = prefix;
	let i = 0;
	while (i < errors.length) {
		msg = msg + " " + errors[i].message;
		i = i + 1;
	}
	return msg;
}

// Full C pipeline: parse → check → monomorphize → validate → transform → native → analyze → codegen
export function compileToC(source: string): CompileResult {
	const pr = parseSource(source);
	if (!pr.ok) return Result.err("parse: " + pr.error);

	const checkerCtx = checkProgram(pr.value);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));

	const monoed = monomorphizeProgram(pr.value, checkerCtx);

	validateTypedAST(checkerCtx, monoed);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "validate:"));

	const transformed = transformProgram(monoed, checkerCtx, false);
	const nativeCtx = createTransformContextWithChecker(checkerCtx);
	const nativeTransformed = transformForNative(transformed, nativeCtx);
	const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
	const aliveSet = createAliveSet();
	return Result.ok(generateCModule(analyzed, checkerCtx, "test/e2e", aliveSet, false));
}

// Full JS pipeline: parse → check → transform(jsBackend=true) → codegen
export function compileToJS(source: string): CompileResult {
	const pr = parseSource(source);
	if (!pr.ok) return Result.err("parse: " + pr.error);

	const checkerCtx = checkProgram(pr.value);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));

	const transformed = transformProgram(pr.value, checkerCtx, true);
	return Result.ok(generateJS(transformed));
}

// String contains check (MetaScript has no indexOf/includes)
export function contains(haystack: string, needle: string): boolean {
	if (needle.length === 0) return true;
	if (haystack.length < needle.length) return false;
	let i = 0;
	const limit = haystack.length - needle.length;
	while (i <= limit) {
		if (sliceStr(haystack, i, i + needle.length) === needle) return true;
		i = i + 1;
	}
	return false;
}

test "contains basic" {
	assert contains("hello world", "world");
	assert contains("hello world", "hello");
	assert !contains("hello", "world");
	assert contains("abc", "");
	assert !contains("", "abc");
}
