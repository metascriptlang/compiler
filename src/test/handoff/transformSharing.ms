import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { ExportRegistry } from "../../checker/context";
import { transformProgram } from "../../transform/index";
import { transformForNative } from "../../transform/native/index";
import { createTransformContextWithChecker } from "../../transform/context";
import { analyzeProgram } from "../../analyzer/index";
import { createRoutineDecls, createWriteSummaries } from "../../analyzer/writeEffects";
import { countSharedNodes } from "../../transform/shareCount";
import { Node } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";

function sharedAfterTransform(source: string, jsBackend: boolean = false): int32 {
	resetBuildState();
	const prelude = preludeContextFor("", jsBackend ? ".jms" : ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("internal: test source does not parse");
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	const program: Node = transformProgram(pr.value, ctx, jsBackend);
	return countSharedNodes(program).shared;
}

function sharedAfterAnalyzer(source: string): int32 {
	resetBuildState();
	const prelude = preludeContextFor("", ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("internal: test source does not parse");
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	const native = transformForNative(transformProgram(pr.value, ctx, false), createTransformContextWithChecker(ctx));
	return countSharedNodes(analyzeProgram(native, ctx, createWriteSummaries(createRoutineDecls(), []))).shared;
}

test "the lifted hooks of a struct with string fields reach no node from two parents" {
	const source = "interface Pair { a: string; b: string; c: string } function userMake(): Pair { const p: Pair = { a: \"x\", b: \"y\", c: \"z\" }; const q = p; return q; }";
	assert sharedAfterTransform(source) == 0;
}

test "the lifted trace of a struct with an array field reaches no node from two parents" {
	const source = "class Cell { next: Cell | null = null; xs: string[] = []; ys: string[] = [] } function userMake(): Cell { return new Cell(); }";
	assert sharedAfterTransform(source) == 0;
}

test "a bit set of 34 members read twice by size() reaches no node from two parents" {
	const source = "enum Wide { A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z, A1, B1, C1, D1, E1, F2, G1, H1 } function userCount(s: BitSet<Wide>): int32 { return s.size(); }";
	assert sharedAfterTransform(source) == 0;
}

test "a power assert on the js backend reaches no node from two parents" {
	const source = "test \"decomposed\" { const a = 1; const b = 2; assert a == b; }";
	assert sharedAfterTransform(source, true) == 0;
}

test "a string field assigned from another field reaches no node from two parents after the analyzer" {
	const source = "class Cell { name: string = \"a\"; tag: string = \"b\"; next: Cell | null = null } function userCopy(a: Cell, b: Cell): void { a.name = b.tag; a.next = new Cell(); }";
	assert sharedAfterAnalyzer(source) == 0;
}

test "a nullable's text read from a call reaches no node from two parents after the analyzer" {
	const source = "function userMaybe(): int32 | null { return 1; } function userText(): string { return userMaybe().toString(); }";
	assert sharedAfterAnalyzer(source) == 0;
}
