import { resetBuildState } from "../../compiler/buildSession";
import { MapEntry, createMapProvider, loadModuleGraph, canonicalModulePath } from "../../module/loader";
import { checkModuleGraph } from "../../checker/orchestrator";
import { hasErrors } from "../../checker/context";
import { lookupModuleCtx, lookupModuleProgram } from "../../checker/instantiate";
import { transformForRaiser } from "../../transform/raiserLowering";
import { generateRaiserProject, RaiserModuleInput } from "../../codegen/raiser/rgen";
import { RaiserValueKind, heapObjectGetField } from "../../raiser/value";
import { unboxFloat } from "../../raiser/marshal";
import { RaiserContext, createContext, load, execute } from "../../raiser/context";

// Checks the modules as one graph and lowers each, as `msc run --target=raiser` does.
// codes[0] is the entry `a.ms`, codes[i] is `<b, c, …>.ms`; a module reaches another
// through `import … from "./b"`.
function runProjectImage(codes: string[]): RaiserContext {
	resetBuildState();
	const names: string[] = ["a", "b", "c", "d", "e", "f"];
	const entries: MapEntry[] = [];
	for (let i = 0; i < codes.length; i += 1) {
		entries.push({ entryPath: canonicalModulePath(`/raiserProject/${names[i]}.ms`), entrySource: codes[i] });
	}
	const graph = loadModuleGraph(entries[0].entryPath, createMapProvider(entries));
	checkModuleGraph(graph, "");
	const modules: RaiserModuleInput[] = [];
	for (const path of graph.loadOrder) {
		const program = lookupModuleProgram(path);
		const modCtx = lookupModuleCtx(path);
		if (program == null || modCtx == null || hasErrors(modCtx)) { unreachable; return createContext(); }
		modules.push({ modulePath: path, program: transformForRaiser(program, modCtx) });
	}
	const raiserMod = generateRaiserProject(modules);
	const ctx = createContext();
	load(ctx, raiserMod);
	execute(ctx);
	return ctx;
}

test "raiserProject: class ctor returns object" {
	const ctx = runProjectImage(["import { Point } from \"./b\"; const p = new Point(42); export default p.x;", "export class Point { x: int32; constructor(x: int32) { this.x = x; } }"]);
	assert ctx.lastResult.intVal == 42;
}

test "raiserProject: class with method" {
	const ctx = runProjectImage(["import { readBox } from \"./b\"; export default readBox();", "class Box { val: int32; constructor(v: int32) { this.val = v; } getVal(): int32 { return this.val; } } export function readBox(): int32 { return new Box(99).getVal(); }"]);
	assert ctx.lastResult.intVal == 99;
}

test "raiserProject: class with multiple methods" {
	const ctx = runProjectImage(["import { calc } from \"./b\"; export default calc();", "class Calc { a: int32; b: int32; constructor(a: int32, b: int32) { this.a = a; this.b = b; } sum(): int32 { return this.a + this.b; } product(): int32 { return this.a * this.b; } } export function calc(): int32 { const m = new Calc(3, 4); return m.sum() + m.product(); }"]);
	assert ctx.lastResult.intVal == 19;
}

test "raiserProject: class and function in same module" {
	const ctx = runProjectImage(["import { Pt, readX } from \"./b\"; const pt = new Pt(55); export default readX(pt);", "export class Pt { x: int32; constructor(x: int32) { this.x = x; } } export function readX(p: Pt): int32 { return p.x; }"]);
	assert ctx.lastResult.intVal == 55;
}

test "raiserProject: single file via project API" {
	const ctx = runProjectImage(["export default 2 + 3;"]);
	assert ctx.lastResult.intVal == 5;
}

test "raiserProject: two modules: no cross-call" {
	const ctx = runProjectImage(["import \"./b\"; export default 42;", "const x = 1;"]);
	assert ctx.lastResult.intVal == 42;
}

test "raiserProject: module with function no call" {
	const ctx = runProjectImage(["import \"./b\"; export default 99;", "export function sumOf(a: int32, b: int32): int32 { return a + b; }"]);
	assert ctx.lastResult.intVal == 99;
}

test "raiserProject: cross-module function call" {
	const ctx = runProjectImage(["import { sumPair } from \"./b\"; export default sumPair(3, 4);", "export function sumPair(a: number, b: number): number { return a + b; }"]);
	assert unboxFloat(ctx.lastResult) == 7;
}

test "raiserProject: multiple functions from same module" {
	const ctx = runProjectImage(["import { sumPair, product } from \"./b\"; export default sumPair(3, 4) + product(2, 5);", "export function sumPair(a: number, b: number): number { return a + b; } export function product(a: number, b: number): number { return a * b; }"]);
	assert unboxFloat(ctx.lastResult) == 17;
}

test "raiserProject: sequential cross-module calls via variable" {
	const ctx = runProjectImage(["import { dbl } from \"./b\"; const x = dbl(3); export default dbl(x);", "export function dbl(x: number): number { return x * 2; }"]);
	assert unboxFloat(ctx.lastResult) == 12;
}

test "raiserProject: nested cross-module call" {
	const ctx = runProjectImage(["import { dbl } from \"./b\"; export default dbl(dbl(3));", "export function dbl(x: number): number { return x * 2; }"]);
	assert unboxFloat(ctx.lastResult) == 12;
}

test "raiserProject: chain: A calls B calls C" {
	const ctx = runProjectImage(["import { quadruple } from \"./b\"; export default quadruple(3);", "import { dbl } from \"./c\"; export function quadruple(x: number): number { return dbl(dbl(x)); }", "export function dbl(x: number): number { return x * 2; }"]);
	assert unboxFloat(ctx.lastResult) == 12;
}

test "raiserProject: diamond dependency" {
	const ctx = runProjectImage(["import { fromC } from \"./b\"; import { fromB } from \"./c\"; export default fromB(10) + fromC(10);", "import { base } from \"./d\"; export function fromC(x: number): number { return base(x) * 3; }", "import { base } from \"./d\"; export function fromB(x: number): number { return base(x) * 2; }", "export function base(x: number): number { return x + 1; }"]);
	assert unboxFloat(ctx.lastResult) == 55;
}

test "raiserProject: module init order" {
	const ctx = runProjectImage(["import \"./b\"; console.log(\"A\");", "console.log(\"B\");"]);
	assert ctx.lastOutput == "B\nA\n";
}

test "raiserProject: cross-module enum" {
	const ctx = runProjectImage(["import { Color } from \"./b\"; export default Color.Blue;", "export enum Color { Red, Green, Blue }"]);
	assert ctx.lastResult.intVal == 2;
}

test "raiserProject: cross-module function with enum" {
	const ctx = runProjectImage(["import { Dir, isVertical } from \"./b\"; export default isVertical(Dir.Up);", "export enum Dir { Up, Down, Left, Right } export function isVertical(d: Dir): int32 { if (d == Dir.Up) { return 1; } if (d == Dir.Down) { return 1; } return 0; }"]);
	assert ctx.lastResult.intVal == 1;
}

test "raiserProject: entry module export default" {
	const ctx = runProjectImage(["import { wrap } from \"./b\"; export default wrap(42);", "export interface Wrapped { value: int32; } export function wrap(x: int32): Wrapped { return { value: x }; }"]);
	assert ctx.lastResult.kind == RaiserValueKind.Object;
	const val = heapObjectGetField(ctx.objectHeap, ctx.lastResult.intVal, "value");
	assert val.intVal == 42;
}

test "raiserProject: recursive function cross-module" {
	const ctx = runProjectImage(["import { fact } from \"./b\"; export default fact(5);", "export function fact(n: number): number { if (n <= 1) { return 1; } return n * fact(n - 1); }"]);
	assert unboxFloat(ctx.lastResult) == 120;
}
