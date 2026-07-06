// Raiser eval — Full pipeline: parse → check → transform → codegen → execute
// Separate file to avoid import graph contamination in rgen.ms tests.


import { Node, Symbol, createNode, NodeKind, ProgramData } from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import { checkProgram, checkProgramWithRegistry, buildPreludeContext, registerSeedSymbols, clearSeedSymbols } from "../../checker/checkPass";
import { ExportRegistry, CheckerContext } from "../../checker/context";
import { resolveRuntimeDir } from "../../utils/path";
import { join } from "std/fs/path";
import { createTransformContextWithChecker } from "../../transform/context";
import { refineTypes } from "../../transform/typeRefine";
import { transformForRaiser } from "../../transform/raiserLowering";
import { RaiserValueKind, RaiserValue, heapObjectGetField, heapObjectGetString } from "../../raiser/value";
import { RaiserInstruction, raiserABC, RaiserOpcode } from "../../raiser/bytecode";
import { RaiserContext, createContext, load, execute } from "../../raiser/context";
import { RaiserVM, execModule, createVM, vmCallFunction } from "../../raiser/vm";
import { RaiserModule, RaiserFunction, createRaiserModule, createRaiserFunction } from "../../raiser/module";
import { RaiserFuncMap } from "./context";
import { moduleScopeSymbols } from "../../checker/symbol";
import { cloneNodeForCheck } from "../../monomorphize/clone";
import { lookupModuleCtx } from "../../checker/instantiate";
import { synthToken } from "../../compiler/meta/bridge";
import { registerRaiserOnDemand } from "./context";
import { generateRaiser, generateRaiserProject, RaiserModuleInput, appendProgramToImage } from "./rgen";
import { getComptimeOuterCtx, registerMacroEngineCompiler, EngineMacroResult } from "../../compiler/meta/callbacks";
import { ensureHostTableLoaded } from "../../compiler/meta/hostTable";

// --- Full Pipeline API ---

export function evalSourceFull(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) return createContext();
	return evalASTFull(parseResult.value);
}

// --- AST-based eval (no parsing step) ---
// Used by @comptime evaluation — takes a pre-built Program node.
//
// Spike 2: if the outer compile pipeline set the multi-module context
// (registry + graph + module + prelude), reuse it via checkProgramWithRegistry
// so cross-module imports inside the @comptime body resolve. Otherwise fall
// back to the single-file checkProgram path (used by direct tests).

// Macros always execute in the Raiser VM, so their std (string/array) methods must
// resolve to the .rms prelude (extern → host functions) regardless of the build
// target. The build target's prelude (e.g. .jms's pure-MS startsWith via asBytes)
// does not run in the VM. Cached — built once per process.
let _raiserPreludeCtx: CheckerContext | null = null;
function raiserPreludeCtx(): CheckerContext {
	if (_raiserPreludeCtx === null) {
		const root = resolveRuntimeDir();
		const stdPath = root !== "" ? join(root, "std") : "";
		_raiserPreludeCtx = buildPreludeContext(stdPath, ".rms");
	}
	return _raiserPreludeCtx;
}

// Check + refineTypes + transformForRaiser over a synthetic Program, ready for
// bytecode generation. Runs the inner pipeline destructively, so the caller must
// pass a Program whose real-module decls are CLONED (never the canonical nodes).
function transformForEngine(program: Node): Node {
	// Macro bodies dispatch string/array builtins through CallHost — the host
	// registry must be populated first (same as @comptime via evalComptimeBlock).
	ensureHostTableLoaded();
	const outer = getComptimeOuterCtx();
	const savedOuterProgram = outer !== null ? outer.program : null as unknown as Node;
	const savedOuterPrelude = outer !== null ? outer.preludeCtx : null as unknown as CheckerContext;
	const hasFullOuterCtx = outer !== null
		&& outer.registry !== null
		&& outer.graph !== null
		&& outer.module !== null
		&& outer.preludeCtx !== null;
	const checkerCtx = hasFullOuterCtx
		? checkProgramWithRegistry(program, outer.registry, outer.graph, outer.module, raiserPreludeCtx())
		: checkProgram(program);
	const txCtx = createTransformContextWithChecker(checkerCtx);
	const refined = refineTypes(program, txCtx, null as unknown as ExportRegistry);
	const transformed = transformForRaiser(refined, checkerCtx);
	if (outer !== null) {
		outer.program = savedOuterProgram;
		outer.preludeCtx = savedOuterPrelude;
	}
	return transformed;
}

export function evalASTCompile(program: Node): RaiserModule {
	return generateRaiser(transformForEngine(program));
}

export function evalASTFull(program: Node): RaiserContext {
	const raiserMod = evalASTCompile(program);
	const ctx = createContext();
	load(ctx, raiserMod);
	execute(ctx);
	return ctx;
}

// --- Comptime engine (Nim graph.vm + PCtx.code parity) ---
// ONE image + funcMap + persistent VM for the whole compilation. Each macro
// wrapper compiles ONCE into the shared image via appendProgramToImage (absolute
// funcIdx, no relocation); per invocation the caller marshals args into registers
// and re-enters through vmCallFunction. Scoped to one compilation by `token`.

interface ComptimeEngine {
	image: RaiserModule;
	funcMap: RaiserFuncMap;
	enumMap: RaiserFuncMap;
	vm: RaiserVM;
	seen: HashMap<string, number>;
}

let _engine: ComptimeEngine = null as unknown as ComptimeEngine;
let _engineToken: CheckerContext = null as unknown as CheckerContext;

function freshEngine(): ComptimeEngine {
	// Seed with a never-called Halt entry so createVM has a valid entry frame;
	// macro functions append at index 1+.
	const entryCode: RaiserInstruction[] = [raiserABC(RaiserOpcode.Halt, 0, 0, 0)];
	const entryConsts: RaiserValue[] = [];
	const entryFn = createRaiserFunction("__engineEntry", entryCode, entryConsts, 0, 0, 2);
	const functions: RaiserFunction[] = [entryFn];
	const image = createRaiserModule("comptime-engine", functions, 0);
	const funcMap: RaiserFuncMap = { items: [] };
	const enumMap: RaiserFuncMap = { items: [] };
	const vm = createVM(image, "arena");
	const seen: HashMap<string, number> = new HashMap<string, number>();
	return { image, funcMap, enumMap, vm, seen };
}

function compileProgramIntoEngine(program: Node, seeds: Symbol[], wantFn: string): number {
	registerSeedSymbols(seeds);
	const transformed = transformForEngine(program);
	clearSeedSymbols();
	return appendProgramToImage(_engine.image, _engine.funcMap, _engine.enumMap, transformed, wantFn);
}

export function compileMacroIntoEngine(program: Node, token: CheckerContext, macroFnName: string): EngineMacroResult {
	if (_engineToken !== token) {
		_engine = freshEngine();
		_engineToken = token;
	}
	const funcIdx = compileProgramIntoEngine(program, moduleScopeSymbols(token.table), macroFnName);
	return { vm: _engine.vm, funcIdx };
}

registerMacroEngineCompiler(compileMacroIntoEngine);

function seedCtxForSym(sym: Symbol): CheckerContext {
	if (sym.modulePath !== "" && _engineToken !== null && sym.modulePath !== _engineToken.modulePath) {
		const mc = lookupModuleCtx(sym.modulePath);
		if (mc !== null) return mc;
	}
	if (_engineToken !== null) return _engineToken;
	return null as unknown as CheckerContext;
}

function ensureCompiledIntoEngine(sym: Symbol): number {
	if (_engine === null) return -1;
	const name = sym.name;
	if (_engine.seen.has(name)) return _engine.seen.get(name);
	if (sym.declNode === null) return -1;
	_engine.seen.set(name, _engine.image.functions.length);
	const seedCtx = seedCtxForSym(sym);
	const seeds: Symbol[] = [];
	if (seedCtx !== null) {
		for (const s of moduleScopeSymbols(seedCtx.table)) {
			if (s.name !== name) seeds.push(s);
		}
	}
	const clone = cloneNodeForCheck(sym.declNode);
	const decls: Node[] = [clone];
	const program = createNode(NodeKind.Program, { programStmts: decls }, synthToken(sym.declNode.location));
	return compileProgramIntoEngine(program, seeds, name);
}

registerRaiserOnDemand(ensureCompiledIntoEngine);

export function evalProgramViaEngine(program: Node, token: CheckerContext, fnName: string): RaiserContext {
	const result = compileMacroIntoEngine(program, token, fnName);
	if (result === null as unknown as EngineMacroResult) return createContext();
	const noArgs: RaiserValue[] = [];
	const resultVal = vmCallFunction(result.vm, result.funcIdx, noArgs);
	return {
		mod: result.vm.mod,
		hasModule: true,
		lastResult: resultVal,
		lastOutput: result.vm.output,
		arrayHeap: result.vm.arrayHeap,
		objectHeap: result.vm.objectHeap,
		lastError: result.vm.error,
		gcMode: result.vm.gcMode,
	};
}

import { registerMacroEvaluator, registerMacroCompiler } from "../../compiler/meta/callbacks";
registerMacroEvaluator(evalASTFull);
registerMacroCompiler(evalASTCompile);

// --- Test helper ---

function evalFull(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) {
		unreachable;
		return createContext();
	}
	return evalASTFull(parseResult.value);
}

// Full pipeline under ORC (gcMode=orc) — returns the VM so heap state is inspectable.
function evalOrcVM(code: string): RaiserVM {
	const parseResult = parseSource(code);
	if (!parseResult.ok) { unreachable; }
	const program = parseResult.value;
	const checkerCtx = checkProgram(program);
	const txCtx = createTransformContextWithChecker(checkerCtx);
	const refined = refineTypes(program, txCtx, null as unknown as ExportRegistry);
	const transformed = transformForRaiser(refined, checkerCtx);
	const mod = generateRaiser(transformed);
	return execModule(mod, "orc");
}

test "orc: correct result + no error on object program" {
	const vm = evalOrcVM("function mk(): { x: number } { return { x: 7 }; } const o = mk(); return o.x;");
	assert vm.error === "";
	assert vm.exitValue.intVal === 7;
}

test "orc: dead objects in loop are reclaimed (free-list grows)" {
	const vm = evalOrcVM("function mk(): { x: number } { return { x: 1 }; } let i = 0; let s = 0; while (i < 40) { const o = mk(); s = s + o.x; i = i + 1; } return s;");
	assert vm.error === "";
	assert vm.exitValue.intVal === 40;
	// arena would grow objectHeap ~40 with empty free-list; orc recycles dead objects
	assert vm.objectHeap.freeList.length > 0;
}

test "orc: heap stays bounded under long alloc loop" {
	const vm = evalOrcVM("function mk(): { x: number } { return { x: 1 }; } let i = 0; while (i < 500) { const o = mk(); i = i + 1; } return i;");
	assert vm.error === "";
	assert vm.exitValue.intVal === 500;
	// arena would grow objectHeap to ~500; orc recycles dead objects → bounded
	assert vm.objectHeap.objects.length < 50;
}

test "orc: reference cycles are collected (bounded heap)" {
	// each mkCycle leaks an a<->b cycle that pure ARC can never free; the cycle
	// collector must reclaim them so the heap stays bounded across 2000 iterations.
	const src = "interface CNode { next: CNode; } function mkCycle(): void { const a: CNode = { next: null as unknown as CNode }; const b: CNode = { next: null as unknown as CNode }; a.next = b; b.next = a; } let i = 0; while (i < 2000) { mkCycle(); i = i + 1; } return 0;";
	const vm = evalOrcVM(src);
	assert vm.error === "";
	// without cycle collection objectHeap would hold ~4000 leaked objects
	assert vm.objectHeap.objects.length < 1000;
}

test "orc: shared ref survives (stored in array)" {
	const vm = evalOrcVM("const a: number[] = []; let i = 0; while (i < 5) { a.push(i); i = i + 1; } let sum = 0; for (const v of a) { sum = sum + v; } return sum;");
	assert vm.error === "";
	assert vm.exitValue.intVal === 10;
}

// --- Phase 3 Integration Tests ---
// These tests verify features that require transforms to work.
test "match expression returns value" {
	const ctx = evalFull("const x = 2; return match (x) { 1 => 10, 2 => 20, _ => 0, };");
	assert ctx.lastResult.intVal === 20;
}

test "match with wildcard" {
	const ctx = evalFull("const x = 99; return match (x) { 1 => 10, _ => 42, };");
	assert ctx.lastResult.intVal === 42;
}

test "match on string" {
	const ctx = evalFull("const s = \"hello\"; return match (s) { \"hello\" => 1, \"world\" => 2, _ => 0, };");
	assert ctx.lastResult.intVal === 1;
}

test "match with when guard" {
	const ctx = evalFull("const x = 2; const flag = true; return match (x) { 2 when flag => 200, 2 => 20, _ => 0, };");
	assert ctx.lastResult.intVal === 200;
}

test "match when guard fails" {
	const ctx = evalFull("const x = 2; const flag = false; return match (x) { 2 when flag => 200, 2 => 20, _ => 0, };");
	assert ctx.lastResult.intVal === 20;
}

test "match simple wildcard default" {
	const ctx = evalFull("const x = 5; return match (x) { 1 => 10, _ => 42, };");
	assert ctx.lastResult.intVal === 42;
}

test "match guarded wildcard" {
	const ctx = evalFull("const x = 5; const flag = true; return match (x) { 1 => 10, _ when flag => 999, _ => 0, };");
	assert ctx.lastResult.intVal === 999;
}

test "existing arithmetic still works" {
	const ctx = evalFull("return 2 + 3 * 4;");
	assert ctx.lastResult.intVal === 14;
}

test "number toString through full pipeline" {
	const ctx = evalFull("return (10).toString() + \"-\" + (20).toString();");
	assert ctx.lastResult.strVal === "10-20";
}

// Enum member access through the FULL pipeline: the checker rewrites `Color.Green`
// → Identifier "Color_Green" before codegen, so the codegen-only enum path
// (evalProject, MemberExpr-based) never exercises this. Without resolution of the
// mangled identifier the VM yields nil / 0 and match-on-enum collapses to arm 0.
test "enum member through full pipeline" {
	const ctx = evalFull("enum Color { Red, Green, Blue } return Color.Green as number;");
	assert ctx.lastResult.intVal === 1;
}

test "enum explicit values through full pipeline" {
	const ctx = evalFull("enum Status { Active = 5, Inactive = 2, Pending = 9 } return Status.Pending as number;");
	assert ctx.lastResult.intVal === 9;
}

test "match on enum through full pipeline" {
	const ctx = evalFull("enum Color { Red, Green, Blue } const c = Color.Blue; return match (c) { Color.Red => 10, Color.Green => 20, Color.Blue => 30, };");
	assert ctx.lastResult.intVal === 30;
}

test "function call through transform" {
	const ctx = evalFull("function add(a, b) { return a + b; } return add(10, 20);");
	assert ctx.lastResult.intVal === 30;
}

test "nested function call (full pipeline)" {
	const ctx = evalFull("function dbl(x) { return x * 2; } return dbl(dbl(3));");
	assert ctx.lastResult.intVal === 12;
}

test "objects through transform" {
	const ctx = evalFull("return { x: 42 };");
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const x = heapObjectGetField(ctx.objectHeap, ctx.lastResult.intVal, "x");
	assert x.intVal === 42;
}

test "build.ms pattern through transform" {
	const ctx = evalFull("import { defineConfig } from \"std/build\"; export default defineConfig({ root: \"src/main.ms\" });");
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const root = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "root");
	assert root === "src/main.ms";
}

test "sum 1..100" {
	const ctx = evalFull("function sum(n: number, acc: number): number { if (n <= 0) { return acc; } return sum(n - 1, acc + n); } return sum(100, 0);");
	assert ctx.lastResult.intVal === 5050;
}

test "arrow no captures" {
	const ctx = evalFull("const f = (x: number): number => x * 2; return f(21);");
	assert ctx.lastResult.intVal === 42;
}

test "arrow block body no captures" {
	const ctx = evalFull("const f = (a: number, b: number): number => { return a + b; }; return f(10, 20);");
	assert ctx.lastResult.intVal === 30;
}

test "arrow used in expression" {
	const ctx = evalFull("const dbl = (x: number): number => x * 2; return dbl(3) + dbl(4);");
	assert ctx.lastResult.intVal === 14;
}

test "arrow passed to function" {
	const ctx = evalFull("function apply(f: (x: number) => number, x: number): number { return f(x); } const dbl = (x: number): number => x * 2; return apply(dbl, 5);");
	assert ctx.lastResult.intVal === 10;
}

test "multiple arrows" {
	const ctx = evalFull("const add1 = (x: number): number => x + 1; const dbl = (x: number): number => x * 2; return dbl(add1(3));");
	assert ctx.lastResult.intVal === 8;
}

// --- Continue inside for-of / for-stmt — regression tests ---
// Pre-fix: ContinueStmt jumped to loopStart (before update step), so
// for-of skipped the increment → infinite loop. patchLoopContinues now
// patches each continue placeholder to the update emit point.
test "continue inside for-of advances index" {
	const ctx = evalFull("const arr = [1, 2, 3, 4, 5]; let sum = 0; for (const x of arr) { if (x === 3) continue; sum = sum + x; } return sum;");
	assert ctx.lastResult.intVal === 12;
}

test "continue inside C-style for runs update" {
	const ctx = evalFull("let sum = 0; for (let i = 0; i < 5; i = i + 1) { if (i === 2) continue; sum = sum + i; } return sum;");
	assert ctx.lastResult.intVal === 8;
}

test "continue inside while re-checks condition" {
	const ctx = evalFull("let i = 0; let sum = 0; while (i < 5) { i = i + 1; if (i === 3) continue; sum = sum + i; } return sum;");
	assert ctx.lastResult.intVal === 12;
}

// --- Nil identity check — kind-aware equality (regression) ---
// Pre-fix: `arr !== null` compiled to BneI64 which only checks intVal;
// Array(handle=0) and Nil both have intVal=0, so the comparison returned
// false-equal. IsNil opcode now performs kind-aware identity (mirrors Nim
// opcIsNil + HashLink OJNotNull).
test "first-allocated array compares correctly against null" {
	const ctx = evalFull("const arr = [1, 2]; return arr !== null ? 1 : 0;");
	assert ctx.lastResult.intVal === 1;
}

test "first-allocated object compares correctly against null" {
	const ctx = evalFull("const o = { x: 1 }; return o !== null ? 1 : 0;");
	assert ctx.lastResult.intVal === 1;
}

test "null === null is true" {
	const ctx = evalFull("return null === null ? 1 : 0;");
	assert ctx.lastResult.intVal === 1;
}

test "null === 0 is false (kind differs)" {
	const ctx = evalFull("return null === 0 ? 1 : 0;");
	assert ctx.lastResult.intVal === 0;
}

// --- Closure with captures ---

// Helper: parse → codegen → execute (no checker, no transforms)
function evalRaiserDirect(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) {
		unreachable;
		return createContext();
	}
	const mod = generateRaiser(parseResult.value);
	const ctx = createContext();
	load(ctx, mod);
	execute(ctx);
	return ctx;
}

// --- Closure capture tests --- (commented out: lambda-lifted closures return 0 via Raiser VM)
// Hand-written closure pairs work; lambda-lifting + full transform pipeline does not.
// Root cause: post-lambda-lifting transforms (likely destructorLifting or DRC interaction)
// corrupt the AST for the Raiser codegen path. Needs further investigation.
//
// testGroup("Raiser Phase 3: closures", () => {
// 	test("capture local variable", () => {
// 		const ctx = evalFull("function make(): number { const x = 42; const f = (): number => x; return f(); } return make();");
// 		check(ctx.lastResult.intVal === 42);
// 	});
// 	test("capture in top-level scope", () => {
// 		const ctx = evalFull("const x = 99; const f = (): number => x; return f();");
// 		check(ctx.lastResult.intVal === 99);
// 	});
// 	test("capture block body top-level", () => {
// 		const ctx = evalFull("const x = 77; const f = (): number => { return x; }; return f();");
// 		check(ctx.lastResult.intVal === 77);
// 	});
// });
test "hand-written closure pair (no transforms)" {
	const ctx = evalRaiserDirect("function lifted(_envP: unknown): number { return _envP.x; } const x = 99; const f = { fn: lifted, env: { x: x } }; return f();");
	assert ctx.lastResult.intVal === 99;
}

test "closure pair nested fn (no transforms)" {
	const ctx = evalRaiserDirect("function liftedFn(_envP: unknown): number { return _envP.x; } function make(): number { const x = 42; const f = { fn: liftedFn, env: { x: x } }; return f(); } return make();");
	assert ctx.lastResult.intVal === 42;
}

test "closure pair multi-field env (no transforms)" {
	const ctx = evalRaiserDirect("function liftedFn(_envP: unknown): number { return _envP.a + _envP.b; } const a = 10; const b = 32; const f = { fn: liftedFn, env: { a: a, b: b } }; return f();");
	assert ctx.lastResult.intVal === 42;
}

// --- Class Tests ---
test "class ctor returns object" {
	const ctx = evalProject(["const p = Point_new(42); return p.x;", "class Point { x: number; constructor(x) { this.x = x; } }"]);
	assert ctx.lastResult.intVal === 42;
}

test "class with method" {
	const ctx = evalProject(["const b = Box_new(99); return b.getVal();", "class Box { val: number; constructor(v) { this.val = v; } getVal() { return this.val; } }"]);
	assert ctx.lastResult.intVal === 99;
}

test "class with multiple methods" {
	const ctx = evalProject(["const m = Calc_new(3, 4); return m.sum() + m.product();", "class Calc { a: number; b: number; constructor(a, b) { this.a = a; this.b = b; } sum() { return this.a + this.b; } product() { return this.a * this.b; } }"]);
	assert ctx.lastResult.intVal === 19;
}

test "class and function in same module" {
	const ctx = evalProject(["const pt = Pt_new(55); return readX(pt);", "class Pt { x: number; constructor(x) { this.x = x; } } function readX(p) { return p.x; }"]);
	assert ctx.lastResult.intVal === 55;
}

// --- Project test helper ---
// Uses parse-only (no checker/transforms) because:
// - Raiser VM is dynamically typed; checker/transforms aren't needed for correctness
//
// codes[0] = entry module, codes[1..n] = dependencies (deepest last).
// Modules are pushed in reverse order so dependencies initialize before the entry.

function evalProject(codes: string[]): RaiserContext {
	const modules: RaiserModuleInput[] = [];
	const names: string[] = ["a", "b", "c", "d", "e", "f"];
	let i = codes.length - 1;
	while (i >= 0) {
		const pr = parseSource(codes[i]);
		if (!pr.ok) { unreachable; return createContext(); }
		const path = "/src/" + names[i] + ".ms";
		const input: RaiserModuleInput = { modulePath: path, program: pr.value };
		modules.push(input);
		i = i - 1;
	}
	const raiserMod = generateRaiserProject(modules);
	const ctx = createContext();
	load(ctx, raiserMod);
	execute(ctx);
	return ctx;
}

// --- Project Tests ---
test "single file via project API" {
	const ctx = evalProject(["return 2 + 3;"]);
	assert ctx.lastResult.intVal === 5;
}

test "two modules: no cross-call" {
	const ctx = evalProject(["return 42;", "const x = 1;"]);
	assert ctx.lastResult.intVal === 42;
}

test "module with function no call" {
	const ctx = evalProject(["return 99;", "function add(a, b) { return a + b; }"]);
	assert ctx.lastResult.intVal === 99;
}

test "cross-module function call" {
	const ctx = evalProject(["return add(3, 4);", "function add(a, b) { return a + b; }"]);
	assert ctx.lastResult.intVal === 7;
}

test "multiple functions from same module" {
	const ctx = evalProject(["return add(3, 4) + mul(2, 5);", "function add(a, b) { return a + b; } function mul(a, b) { return a * b; }"]);
	assert ctx.lastResult.intVal === 17;
}

test "sequential cross-module calls via variable" {
	const ctx = evalProject(["const x = dbl(3); return dbl(x);", "function dbl(x) { return x * 2; }"]);
	assert ctx.lastResult.intVal === 12;
}

test "nested cross-module call" {
	const ctx = evalProject(["return dbl(dbl(3));", "function dbl(x) { return x * 2; }"]);
	assert ctx.lastResult.intVal === 12;
}

test "chain: A calls B calls C" {
	const ctx = evalProject(["return quadruple(3);", "function quadruple(x) { return dbl(dbl(x)); }", "function dbl(x) { return x * 2; }"]);
	assert ctx.lastResult.intVal === 12;
}

test "diamond dependency" {
	const ctx = evalProject(["return fromB(10) + fromC(10);", "function fromC(x) { return base(x) * 3; }", "function fromB(x) { return base(x) * 2; }", "function base(x) { return x + 1; }"]);
	assert ctx.lastResult.intVal === 55;
}

test "module init order" {
	const ctx = evalProject(["console.log(\"A\");", "console.log(\"B\");"]);
	assert ctx.lastOutput === "B\nA\n";
}

test "cross-module enum" {
	const ctx = evalProject(["return Color.Blue;", "enum Color { Red, Green, Blue }"]);
	assert ctx.lastResult.intVal === 2;
}

test "cross-module function with enum" {
	const ctx = evalProject(["return isVertical(Dir.Up);", "enum Dir { Up, Down, Left, Right } function isVertical(d) { if (d == Dir.Up) { return 1; } if (d == Dir.Down) { return 1; } return 0; }"]);
	assert ctx.lastResult.intVal === 1;
}

test "entry module export default" {
	const ctx = evalProject(["export default wrap(42);", "function wrap(x) { return { value: x }; }"]);
	assert ctx.lastResult.kind === RaiserValueKind.Object;
	const val = heapObjectGetField(ctx.objectHeap, ctx.lastResult.intVal, "value");
	assert val.intVal === 42;
}

test "recursive function cross-module" {
	const ctx = evalProject(["return fact(5);", "function fact(n) { if (n <= 1) { return 1; } return n * fact(n - 1); }"]);
	assert ctx.lastResult.intVal === 120;
}

// Regression: chained MemberExpr through nested ObjectLiteral.
// Was broken because Raiser's resetTemps used locals.length, assuming locals
// pack at R[0..length-1] — but chained `t.nodeType.kind` allocates an
// intermediate temp at R1 (inner LoadField result) before declaring `k` at R2,
// leaving R1 as a non-local slot. Next stmt's allocReg returned R2, clobbering
// the local. Fix: nextReg = max(local.reg)+1 (context.ms resetTemps).
test "regression: chained MemberExpr through nested ObjectLiteral" {
	const ctx = evalFull(`
const t = { kind: 6, nodeType: { kind: 76, name: "Ref" } };
return t.nodeType.kind;
`);
	assert ctx.lastResult.intVal === 76;
}

test "regression: split MemberExpr through nested ObjectLiteral (control)" {
	const ctx = evalFull(`
const t = { kind: 6, nodeType: { kind: 76, name: "Ref" } };
const nt = t.nodeType;
return nt.kind;
`);
	assert ctx.lastResult.intVal === 76;
}

// Reproduces the original chained-vs-clobber scenario more precisely:
// declare `t` (R0), do chained `k = t.nodeType.kind` (R1 temp, R2=k local with
// R1 gap), then declare another local — pre-fix R2 was clobbered. Verifies
// k's value survives through the next statement.
test "regression: local at non-contiguous register survives next stmt" {
	const ctx = evalFull(`
const t = { kind: 6, nodeType: { kind: 76, name: "Ref" } };
const k = t.nodeType.kind;
const filler = "anything";
return k;
`);
	assert ctx.lastResult.intVal === 76;
}
