// Raiser eval — Full pipeline: parse → check → transform → codegen → execute
// Separate file to avoid import graph contamination in rgen.ms tests.

import { test, check, testGroup } from "std/testing";
import { Node } from "../../ast/node";
import { parseSource } from "../../parser/index";
import { checkProgram } from "../../checker/index";
import { transformProgram } from "../../transform/index";
import {
	RaiserValueKind, RaiserValue,
	heapObjectGetField, heapObjectGetString, heapObjectGetObjectHandle,
	heapArrayGet, heapArrayLen
} from "../../raiser/value";
import { RaiserContext, createContext, load, execute } from "../../raiser/context";
import { generateRaiser, generateRaiserProject, RaiserModuleInput } from "./rgen";

// --- Full Pipeline API ---

export function evalSourceFull(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) return createContext();
	return evalASTFull(parseResult.value);
}

// --- AST-based eval (no parsing step) ---
// Used by @comptime evaluation — takes a pre-built Program node.

export function evalASTFull(program: Node): RaiserContext {
	const checkerCtx = checkProgram(program);
	const transformed = transformProgram(program, checkerCtx, false);
	const mod = generateRaiser(transformed);
	const ctx = createContext();
	load(ctx, mod);
	execute(ctx);
	return ctx;
}

// --- Test helper ---

function evalFull(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) {
		check(false);
		return createContext();
	}
	return evalASTFull(parseResult.value);
}

// --- Phase 3 Integration Tests ---
// These tests verify features that require transforms to work.

testGroup("Raiser Phase 3: match", () => {
	test("match expression returns value", () => {
		const ctx = evalFull("const x = 2; return match (x) { 1 => 10, 2 => 20, _ => 0, };");
		check(ctx.lastResult.intVal === 20);
	});

	test("match with wildcard", () => {
		const ctx = evalFull("const x = 99; return match (x) { 1 => 10, _ => 42, };");
		check(ctx.lastResult.intVal === 42);
	});

	test("match on string", () => {
		const ctx = evalFull("const s = \"hello\"; return match (s) { \"hello\" => 1, \"world\" => 2, _ => 0, };");
		check(ctx.lastResult.intVal === 1);
	});
});

testGroup("Raiser Phase 3: basics", () => {
	test("existing arithmetic still works", () => {
		const ctx = evalFull("return 2 + 3 * 4;");
		check(ctx.lastResult.intVal === 14);
	});

	test("function call through transform", () => {
		const ctx = evalFull("function add(a, b) { return a + b; } return add(10, 20);");
		check(ctx.lastResult.intVal === 30);
	});

	test("nested function call (single module, full pipeline)", () => {
		const ctx = evalFull("function dbl(x) { return x * 2; } return dbl(dbl(3));");
		check(ctx.lastResult.intVal === 12);
	});

	test("objects through transform", () => {
		const ctx = evalFull("return { x: 42 };");
		check(ctx.lastResult.kind === RaiserValueKind.Object);
		const x = heapObjectGetField(ctx.objectHeap, ctx.lastResult.intVal, "x");
		check(x.intVal === 42);
	});

	test("build.ms pattern through transform", () => {
		const ctx = evalFull("import { defineConfig } from \"std/build\"; export default defineConfig({ root: \"src/main.ms\" });");
		check(ctx.lastResult.kind === RaiserValueKind.Object);
		const root = heapObjectGetString(ctx.objectHeap, ctx.lastResult.intVal, "root");
		check(root === "src/main.ms");
	});
});

testGroup("Raiser Phase 3: tail call", () => {
	test("sum 1..100", () => {
		const ctx = evalFull("function sum(n: number, acc: number): number { if (n <= 0) { return acc; } return sum(n - 1, acc + n); } return sum(100, 0);");
		check(ctx.lastResult.intVal === 5050);
	});
});

testGroup("Raiser Phase 3: arrow", () => {
	test("arrow no captures", () => {
		const ctx = evalFull("const f = (x: number): number => x * 2; return f(21);");
		check(ctx.lastResult.intVal === 42);
	});

	test("arrow block body no captures", () => {
		const ctx = evalFull("const f = (a: number, b: number): number => { return a + b; }; return f(10, 20);");
		check(ctx.lastResult.intVal === 30);
	});

	test("arrow used in expression", () => {
		const ctx = evalFull("const dbl = (x: number): number => x * 2; return dbl(3) + dbl(4);");
		check(ctx.lastResult.intVal === 14);
	});

	test("arrow passed to function", () => {
		const ctx = evalFull("function apply(f: (x: number) => number, x: number): number { return f(x); } const dbl = (x: number): number => x * 2; return apply(dbl, 5);");
		check(ctx.lastResult.intVal === 10);
	});

	test("multiple arrows", () => {
		const ctx = evalFull("const add1 = (x: number): number => x + 1; const dbl = (x: number): number => x * 2; return dbl(add1(3));");
		check(ctx.lastResult.intVal === 8);
	});
});

// --- Closure with captures ---

testGroup("Raiser Phase 3: closures", () => {
	test("capture local variable", () => {
		const ctx = evalFull("function make(): number { const x = 42; const f = (): number => x; return f(); } return make();");
		check(ctx.lastResult.intVal === 42);
	});

	test("capture in top-level scope", () => {
		const ctx = evalFull("const x = 99; const f = (): number => x; return f();");
		check(ctx.lastResult.intVal === 99);
	});
});

// --- Class Tests ---

testGroup("Raiser classes (multi-module)", () => {
	test("class ctor returns object", () => {
		const ctx = evalProject(["const p = Point_new(42); return p.x;", "class Point { x: number; constructor(x) { this.x = x; } }"]);
		check(ctx.lastResult.intVal === 42);
	});

	test("class with method", () => {
		const ctx = evalProject(["const b = Box_new(99); return b.getVal();", "class Box { val: number; constructor(v) { this.val = v; } getVal() { return this.val; } }"]);
		check(ctx.lastResult.intVal === 99);
	});

	test("class with multiple methods", () => {
		const ctx = evalProject(["const m = Calc_new(3, 4); return m.sum() + m.product();", "class Calc { a: number; b: number; constructor(a, b) { this.a = a; this.b = b; } sum() { return this.a + this.b; } product() { return this.a * this.b; } }"]);
		check(ctx.lastResult.intVal === 19);
	});

	test("class and function in same module", () => {
		const ctx = evalProject(["const pt = Pt_new(55); return readX(pt);", "class Pt { x: number; constructor(x) { this.x = x; } } function readX(p) { return p.x; }"]);
		check(ctx.lastResult.intVal === 55);
	});
});

// --- Multi-module test helper ---
// Uses parse-only (no checker/transforms) because:
// - Per-module checkProgram doesn't know about cross-module symbols
// - transformProgram restructures calls to unknown functions (crashes)
// - Raiser VM is dynamically typed; checker/transforms aren't needed for correctness
// For single-module, evalFull (with full pipeline) still works via the tests above.
//
// codes[0] = entry module, codes[1..n] = dependencies (deepest last).
// Modules are pushed in reverse order so dependencies initialize before the entry.

function evalProject(codes: string[]): RaiserContext {
	const modules: RaiserModuleInput[] = [];
	const names: string[] = ["a", "b", "c", "d", "e", "f"];
	let i = codes.length - 1;
	while (i >= 0) {
		const pr = parseSource(codes[i]);
		if (!pr.ok) { check(false); return createContext(); }
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

// --- Multi-module Tests ---

testGroup("Raiser multi-module", () => {
	test("single module via project API", () => {
		const ctx = evalProject(["return 2 + 3;"]);
		check(ctx.lastResult.intVal === 5);
	});

	test("two modules: no cross-call", () => {
		const ctx = evalProject(["return 42;", "const x = 1;"]);
		check(ctx.lastResult.intVal === 42);
	});

	test("module with function no call", () => {
		const ctx = evalProject(["return 99;", "function add(a, b) { return a + b; }"]);
		check(ctx.lastResult.intVal === 99);
	});

	test("cross-module function call", () => {
		const ctx = evalProject(["return add(3, 4);", "function add(a, b) { return a + b; }"]);
		check(ctx.lastResult.intVal === 7);
	});

	test("multiple functions from same module", () => {
		const ctx = evalProject(["return add(3, 4) + mul(2, 5);", "function add(a, b) { return a + b; } function mul(a, b) { return a * b; }"]);
		check(ctx.lastResult.intVal === 17);
	});

	test("sequential cross-module calls via variable", () => {
		const ctx = evalProject(["const x = dbl(3); return dbl(x);", "function dbl(x) { return x * 2; }"]);
		check(ctx.lastResult.intVal === 12);
	});

	test("nested cross-module call", () => {
		const ctx = evalProject(["return dbl(dbl(3));", "function dbl(x) { return x * 2; }"]);
		check(ctx.lastResult.intVal === 12);
	});

	test("chain: A calls B calls C", () => {
		const ctx = evalProject(["return quadruple(3);", "function quadruple(x) { return dbl(dbl(x)); }", "function dbl(x) { return x * 2; }"]);
		check(ctx.lastResult.intVal === 12);
	});

	test("diamond dependency", () => {
		const ctx = evalProject(["return fromB(10) + fromC(10);", "function fromC(x) { return base(x) * 3; }", "function fromB(x) { return base(x) * 2; }", "function base(x) { return x + 1; }"]);
		check(ctx.lastResult.intVal === 55);
	});

	test("module init order", () => {
		const ctx = evalProject(["console.log(\"A\");", "console.log(\"B\");"]);
		check(ctx.lastOutput === "B\nA\n");
	});

	test("cross-module enum", () => {
		const ctx = evalProject(["return Color.Blue;", "enum Color { Red, Green, Blue }"]);
		check(ctx.lastResult.intVal === 2);
	});

	test("cross-module function with enum", () => {
		const ctx = evalProject(["return isVertical(Dir.Up);", "enum Dir { Up, Down, Left, Right } function isVertical(d) { if (d == Dir.Up) { return 1; } if (d == Dir.Down) { return 1; } return 0; }"]);
		check(ctx.lastResult.intVal === 1);
	});

	test("entry module export default", () => {
		const ctx = evalProject(["export default wrap(42);", "function wrap(x) { return { value: x }; }"]);
		check(ctx.lastResult.kind === RaiserValueKind.Object);
		const val = heapObjectGetField(ctx.objectHeap, ctx.lastResult.intVal, "value");
		check(val.intVal === 42);
	});

	test("recursive function cross-module", () => {
		const ctx = evalProject(["return fact(5);", "function fact(n) { if (n <= 1) { return 1; } return n * fact(n - 1); }"]);
		check(ctx.lastResult.intVal === 120);
	});
});
