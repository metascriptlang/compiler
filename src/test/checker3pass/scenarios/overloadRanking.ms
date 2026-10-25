import { checkOnly } from "../helpers";
import { resetBuildState } from "../../../compiler/buildSession";
import { MapEntry, createMapProvider, loadModuleGraph, canonicalModulePath } from "../../../module/loader";
import { checkModuleGraph } from "../../../checker/orchestrator";
import { lookupModuleCtx } from "../../../checker/instantiate";

test "an unannotated arrow that fits two overloads equally is an error that asks for annotations" {
	const src = `
function fn(cb: (x: int32) => int32): string { return "int"; }
function fn(cb: (x: string) => string): string { return "str"; }
function nf(cb: (x: string) => string): string { return "str"; }
function nf(cb: (x: int32) => int32): string { return "int"; }
function pre(n: int32, cb: (x: int32) => int32): string { return "int"; }
function pre(n: int32, cb: (x: string) => string): string { return "str"; }
class Runner {
	run(cb: (x: int32) => int32): string { return "int"; }
	run(cb: (x: string) => string): string { return "str"; }
}
class Cell { n: int32 = 1; }
function at(this c: Cell, cb: (x: int32) => int32): string { return "int"; }
function at(this c: Cell, cb: (x: string) => string): string { return "str"; }
const a = fn((x) => x + x);
const b = nf((x) => x + x);
const c = pre(1, (x) => x + x);
const d = new Runner().run((x) => x + x);
const e = new Cell().at((x) => x + x);
const ok1 = fn((x: int32): int32 => x + x);
const ok2 = fn((x) => x * 2);
`;
	const errors = checkOnly(src).errors;
	const text = errors.join("\n");
	const hint = "fits more than one overload; annotate its parameter types";
	assert text.contains("Ambiguous call to overloaded function 'fn' — a callback or object literal argument " + hint), "function: " + text;
	assert text.contains("Ambiguous call to overloaded function 'nf' — a callback or object literal argument " + hint), "reversed order: " + text;
	assert text.contains("Ambiguous call to overloaded function 'pre' — a callback or object literal argument " + hint), "after a plain argument: " + text;
	assert text.contains("'run' — a callback or object literal argument " + hint), "method: " + text;
	assert text.contains("Ambiguous call to overloaded extension method 'at' — a callback or object literal argument " + hint), "extension: " + text;
	assert errors.length == 5, "annotated or single-fit arrows resolve: " + text;
}

function extensionErrors(entrySource: string): string {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: canonicalModulePath("/overloadRanking/a.ms"), entrySource },
		{ entryPath: canonicalModulePath("/overloadRanking/b.ms"), entrySource: "export class Box { size(): int32 { return 1; } grow(n: int32): int32 { return n; } }\nexport class Animal { speak(): string { return \"a\"; } }\nexport class Dog extends Animal { }\n" },
	];
	checkModuleGraph(loadModuleGraph(entries[0].entryPath, createMapProvider(entries)), "");
	const ctx = lookupModuleCtx(entries[0].entryPath);
	if (ctx == null) return "no module context";
	return ctx.errors.map((e) => e.message + " @" + e.line.toString()).join("\n");
}

test "an extension that repeats a method of its receiver is refused at the extension" {
	const local = checkOnly(`
class Box { size(): int32 { return 1; } grow(n: int32): int32 { return n; } }
function size(this b: Box): int32 { return 2; }
function grow(this b: Box, n: int32): int32 { return n * 2; }
function grow(this b: Box, n: string): int32 { return 7; }
function size(this b: Box, k: int32): int32 { return k; }
`).errors.join("\n");
	assert local.contains("Box already has method size(); an extension with the same name and parameters would shadow it"), "same module, no call: " + local;
	assert local.contains("Box already has method grow(int32)"), "a parameter: " + local;
	assert !local.contains("grow(string)") && !local.contains("size(int32)"), "other parameters stay an overload: " + local;
	const imported = extensionErrors(`import { Box, Dog } from "./b";
function size(this b: Box): int32 { return 2; }
function speak(this d: Dog): string { return "d"; }
function grow(this b: Box, n: string): int32 { return 7; }
const n = new Box().size() + new Box().grow("x");
`);
	assert imported.contains("Box already has method size(); an extension with the same name and parameters would shadow it @2"), "class from another module: " + imported;
	assert imported.contains("Dog already has method speak(); an extension with the same name and parameters would shadow it @3"), "inherited method: " + imported;
	assert !imported.contains("grow"), "a new parameter type is an overload: " + imported;
	const generic = checkOnly(`
class Box { size(): int32 { return 1; } onDestroy(): void { } }
function size<T>(this x: T): int32 { return 3; }
function onDestroy<T>(this x: Readonly<T>): void { }
`).errors.join("\n");
	assert !generic.contains("already has method"), "a receiver that is a type parameter repeats no class's method: " + generic;
}

test "an overload that differs only by a defaulted parameter stays ambiguous" {
	const src = `
function o(x: int32): string { return "one"; }
function o(x: int32, y: int32 = 0): string { return "two"; }
const a = o(1);
const b = o(1, 2);
`;
	const errors = checkOnly(src).errors;
	const text = errors.join("\n");
	assert text.contains("Ambiguous call to overloaded function 'o'"), "one argument: " + text;
	assert errors.length == 1, "two arguments pick the second: " + text;
}
