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
import { generateJS } from "../codegen/js/index";
import { sliceStr } from "../utils/string";

// Full C pipeline: parse → check → monomorphize → validate → transform → native → analyze → codegen
export function compileToC(source: string): string {
	const pr = parseSource(source);
	if (!pr.ok) return "ERROR: parse: " + pr.error;

	const checkerCtx = checkProgram(pr.value);
	if (hasErrors(checkerCtx)) {
		let msg = "ERROR: check:";
		let ei = 0;
		while (ei < checkerCtx.errors.length) {
			msg = msg + " " + checkerCtx.errors[ei];
			ei = ei + 1;
		}
		console.log("C Compile Error (check): " + msg);
		return msg;
	}

	const monoed = monomorphizeProgram(pr.value, checkerCtx);

	validateTypedAST(checkerCtx, monoed);
	if (hasErrors(checkerCtx)) {
		let msg = "ERROR: validate:";
		let ei = 0;
		while (ei < checkerCtx.errors.length) {
			msg = msg + " " + checkerCtx.errors[ei];
			ei = ei + 1;
		}
		console.log("C Compile Error (validate): " + msg);
		return msg;
	}

	const transformed = transformProgram(monoed, checkerCtx, false);
	const nativeCtx = createTransformContextWithChecker(checkerCtx);
	const nativeTransformed = transformForNative(transformed, nativeCtx);
	const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
	return generateCModule(analyzed, checkerCtx, "test/e2e", "");
}

// Full JS pipeline: parse → check → transform(jsBackend=true) → codegen
export function compileToJS(source: string): string {
	const pr = parseSource(source);
	if (!pr.ok) return "ERROR: parse: " + pr.error;

	const checkerCtx = checkProgram(pr.value);
	if (hasErrors(checkerCtx)) {
		let msg = "ERROR: check:";
		let ei = 0;
		while (ei < checkerCtx.errors.length) {
			msg = msg + " " + checkerCtx.errors[ei];
			ei = ei + 1;
		}
		console.log("JS Compile Error (check): " + msg);
		return msg;
	}

	const transformed = transformProgram(pr.value, checkerCtx, true);
	return generateJS(transformed);
}

// String contains check (MetaScript has no indexOf/includes)
export function assertContains(haystack: string, needle: string): boolean {
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

// Assert output is NOT an error
export function assertNoError(output: string): boolean {
	if (output.length >= 6 && sliceStr(output, 0, 6) === "ERROR:") return false;
	return true;
}

import { check } from "std/testing";

test "assertContains basic" {
	check(assertContains("hello world", "world"));
	check(assertContains("hello world", "hello"));
	check(!assertContains("hello", "world"));
	check(assertContains("abc", ""));
	check(!assertContains("", "abc"));
}

test "assertNoError" {
	check(assertNoError("int32_t x = 42;"));
	check(!assertNoError("ERROR: parse: unexpected token"));
}
