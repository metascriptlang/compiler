import { emitDeclarations, DeclarationResult, DeclarationModule } from "../../compiler/declarations";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramJs } from "../../checker/checkPass";
import { hasErrors } from "../../checker/context";
import { resetBuildState } from "../../compiler/buildSession";
import { checkModuleGraph } from "../../checker/orchestrator";
import {
	lookupModuleCtx, lookupModuleProgram,
} from "../../checker/instantiate";
import {
	MapEntry, createMapProvider, canonicalModulePath,
	loadModuleGraphWithConfig,
} from "../../module/loader";
import { createDefaultConfig, Backend } from "../../module/resolver";
import { platform } from "std/process";
import { lookupSymbol } from "../../checker/symbol";

function graphDeclarations(
	entries: MapEntry[],
	entryPath: string,
): DeclarationResult {
	resetBuildState();
	const root = canonicalModulePath(entryPath);
	const canonicalEntries: MapEntry[] = [];
	for (const source of entries) {
		canonicalEntries.push({ entryPath: canonicalModulePath(source.entryPath),
			entrySource: source.entrySource });
	}
	const graph = loadModuleGraphWithConfig(root, createMapProvider(canonicalEntries),
		createDefaultConfig(Backend.JS, ""));
	checkModuleGraph(graph, "", ".jms", platform);
	const modules: DeclarationModule[] = [];
	for (const source of entries) {
		const path = canonicalModulePath(source.entryPath);
		const program = lookupModuleProgram(path);
		const ctx = lookupModuleCtx(path);
		if (program == null || ctx == null) {
			throw new Error("declaration fixture module was not checked: " + path);
		}
		if (hasErrors(ctx)) {
			let message = "declaration fixture graph check:";
			for (const error of ctx.errors) message += " " + error.message;
			throw new Error(message);
		}
		modules.push({ sourcePath: path, program, ctx });
	}
	return emitDeclarations(modules,
		(fromPath: string, toPath: string): string => "mapped:" + toPath,
		[root]);
}

function declarationMessages(result: DeclarationResult): string {
	const messages: string[] = [];
	for (const diagnostic of result.diagnostics) messages.push(diagnostic.message);
	return messages.join("\n");
}

function declarationOf(
	source: string, clearDefaultOf: string = "",
): DeclarationResult {
	resetBuildState();
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error("declaration fixture parse: " + parsed.error);
	const program = parsed.value;
	const ctx = checkProgramJs(program);
	if (hasErrors(ctx)) {
		let message = "declaration fixture check:";
		for (const error of ctx.errors) message += " " + error.message;
		throw new Error(message);
	}
	if (clearDefaultOf != "") {
		lookupSymbol(ctx.table, clearDefaultOf)!.typeParams[0].typeParamDefault = null;
	}
	return emitDeclarations(
		[{ sourcePath: "api.ms", program, ctx }],
		(fromPath: string, toPath: string): string => "./" + toPath + ".js",
		["api.ms"],
	);
}

test "declarations emit inferred public return before lowering" {
	const result = declarationOf(
		"export function greeting() { return \"hello\"; }",
	);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files.length == 1;
	assert result.files[0].text.contains("function greeting(): string;");
}

test "declarations close private supporting types without exporting them" {
	const result = declarationOf(`
interface Leaf { text: string; }
interface Branch { leaf: Leaf; }
export function read(branch: Branch): string { return branch.leaf.text; }
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	const text = result.files[0].text;
	assert text.contains("interface Branch");
	assert text.contains("interface Leaf");
	assert !text.contains("export type { Branch");
	assert !text.contains("export type { Leaf");
}

test "declarations preserve named recursive interface identity" {
	const result = declarationOf(`
export interface Tree { name: string; children: Tree[]; }
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files[0].text.contains("Array<Tree>");
	assert result.files[0].text.contains("export type { Tree }");
}

test "declarations preserve type aliases rather than expand their uses" {
	const result = declarationOf(`
type Label = string;
export function label(value: Label): Label { return value; }
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files[0].text.contains("type Label = string;");
	assert result.files[0].text.contains("value: Label): Label");
}

test "declarations preserve generic type binders and constraints" {
	const result = declarationOf(`
export interface Box<T extends { name: string }> { value: T; }
export type List<T extends string> = T[];
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files[0].text.contains("Box<T extends"), result.files[0].text;
	assert result.files[0].text.contains("\"value\": T");
	assert result.files[0].text.contains("type List<T extends string> = Array<T>"),
		result.files[0].text;
}

test "declarations preserve readonly optional and nullable fields" {
	const result = declarationOf(`
export interface Options { readonly title?: string; value: int32 | null; }
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files[0].text.contains("readonly \"title\"?:");
	assert result.files[0].text.contains("null");
	assert result.files[0].text.contains("\"value\": (number | null)");
}

test "declarations expose wide integers as bigint and narrow integers as number" {
	const result = declarationOf(`
export function wide(value: int64): uint64 { return value as uint64; }
export function narrow(value: int32): float64 { return value as float64; }
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files[0].text.contains("wide(value: bigint): bigint;");
	assert result.files[0].text.contains("narrow(value: number): number;");
}

test "declarations serialize optional and rest type-only signatures" {
	const result = declarationOf(`
export type OptionalCallback = (first?: int32) => int32;
export type RestCallback = (...rest: int32[]) => int32;
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files[0].text.contains("first?:");
	assert result.files[0].text.contains("...rest: Array<number>");
}

test "declarations free functions refuse omitted and spread raw host ABI" {
	for (const source of [
		"export function read(value: int32 = 7): int32 { return value; }",
		"export function read(value?: string): string { return \"x\"; }",
		"export function read(...value: int32[]): int32 { return 1; }",
	]) {
		const result = declarationOf(source);
		assert result.files.length == 0;
		const message = declarationMessages(result);
		assert message.contains("read") && message.contains("value"), message;
		assert message.contains("ABI") && message.contains("pending host adaptation"), message;
	}
}

test "declarations public callbacks reject aliases arrays objects and returned callbacks" {
	for (const source of [
		`type Callback = (value?: int32) => int32;
export function read(callback: Callback): int32 { return 1; }`,
		`type Callback = (...value: int32[]) => int32;
interface Shape { callbacks: Callback[]; next: Shape | null; }
export function read(shape: Shape): int32 { return 1; }`,
		`type Callback = (value?: int32) => int32;
export const read: Callback = (value?: int32): int32 => 1;`,
		`type Callback = (value?: int32) => int32;
export const read: Callback[] = [];`,
		`type Callback = (value?: int32) => int32;
interface Shape { callback: Callback | null; }
export const read: Shape = { callback: null };`,
		`type Callback = (value?: int32) => int32;
export function read(): Callback { return (value?: int32): int32 => 1; }`,
		`type Callback = (value?: int32) => int32;
interface Shape { callback: Callback | null; }
export function read(): Shape[] { return []; }`,
		`export default (value?: int32): int32 => 1;`,
	]) {
		const result = declarationOf(source);
		assert result.files.length == 0;
		const message = declarationMessages(result);
		assert message.contains("raw JS callback calling convention"), message;
		assert message.contains("pending host adaptation"), message;
		assert message.contains("value"), message;
	}
}

test "declarations do not treat private callback implementations as boundaries" {
	const result = declarationOf(`
type Callback = (value?: int32) => int32;
function hidden(value: int32 = 1): int32 { return value; }
export type Shape = { callback: Callback };
export function read(value: int32, callback: (n: int32) => int32): int32 {
	return callback(value);
}
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert !result.files[0].text.contains("hidden");
}

test "declarations serialize callback signatures" {
	const result = declarationOf(`
export function apply(value: string, callback: (input: string) => int32): int32 {
	return callback(value);
}
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files[0].text.contains("callback: ((input: string) => number)");
}

test "declarations wrap auto async returns without inspecting nested awaits" {
	const result = declarationOf(`
export function delayed(value: Promise<int32>): int32 { return await value; }
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files[0].text.contains("): Promise<number>;");
}

test "declarations emit default expression and default function types" {
	const value = declarationOf("export default 4;");
	assert value.diagnostics.length == 0;
	assert value.files[0].text.contains("export default __declarationDefault;");
	const fn = declarationOf("export default function greet(): string { return \"hi\"; }");
	assert fn.diagnostics.length == 0;
	assert fn.files[0].text.contains("greet as default");
	assert !fn.files[0].text.contains("export { greet };");
}

test "declarations refuse specialized runtime generics with locations" {
	const result = declarationOf("export function identity<T>(value: T): T { return value; }");
	assert result.files.length == 0;
	assert result.diagnostics.length > 0;
	assert result.diagnostics[0].message.contains("runtime generic");
	assert result.diagnostics[0].sourcePath == "api.ms";
	assert result.diagnostics[0].line == 1;
}

test "declarations preserve ordinary class constructor and inferred method" {
	const result = declarationOf(`
export class Counter {
	value: int32 = 0;
	constructor(value: int32) { this.value = value; }
	add(amount: int32) { return this.value + amount; }
}
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	const text = result.files[0].text;
	assert text.contains("declare class Counter");
	assert text.contains("#private;");
	assert text.contains("constructor(value: number);");
	assert text.contains("\"value\": number;");
	assert text.contains("\"add\"(amount: number): number;");
	assert !text.contains("arg0");
}

test "declarations refuse native pointer parameters without any fallback" {
	const result = declarationOf("export function opaque(value: Ptr<int32>): void {}");
	assert result.files.length == 0;
	assert result.diagnostics.length > 0;
	assert result.diagnostics[0].message.contains("unsupported public type");
}

test "declarations refuse distinct native identity rather than erase it" {
	const result = declarationOf("export type Handle = distinct int32;");
	assert result.files.length == 0;
	assert result.diagnostics.length > 0;
}

test "declarations roots exclude unrelated generic runtime exports" {
	const result = graphDeclarations([
		{ entryPath: "test/public.ms", entrySource: `
import { identity } from "./unrelated";
export function count(): int32 { return 4; }
` },
		{ entryPath: "test/unrelated.ms", entrySource:
			"export function identity<T>(value: T): T { return value; }" },
	], "test/public.ms");
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files.length == 1;
	assert result.files[0].text.contains("function count");
}

test "declarations retain exact foreign type identities and caller mapping" {
	const result = graphDeclarations([
		{ entryPath: "test/public.ms", entrySource: `
import { Shape as Left } from "./left";
import { Shape as Right } from "./right";
export function left(value: Left): Left { return value; }
export function right(value: Right): Right { return value; }
` },
		{ entryPath: "test/left.ms", entrySource:
			"export interface Shape { x: int32; }" },
		{ entryPath: "test/right.ms", entrySource:
			"export interface Shape { y: string; }" },
	], "test/public.ms");
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files.length == 3;
	const text = result.files[0].text;
	assert text.contains("Shape as __declarationType0");
	assert text.contains("Shape as __declarationType1");
	assert text.contains("mapped:" + canonicalModulePath("test/left.ms"));
	assert text.contains("mapped:" + canonicalModulePath("test/right.ms"));
}

test "declarations named type reexports select only reachable module API" {
	const result = graphDeclarations([
		{ entryPath: "test/public.ms", entrySource:
			"export type { Item as PublicItem } from \"./model\";" },
		{ entryPath: "test/model.ms", entrySource: `
export interface Item { id: int64; }
export function identity<T>(value: T): T { return value; }
` },
	], "test/public.ms");
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files.length == 2;
	assert result.files[0].text.contains("export type { Item as PublicItem }");
	assert result.files[1].text.contains("interface Item");
	assert !result.files[1].text.contains("identity");
}

test "declarations refuse a foreign private inferred nominal name" {
	const result = graphDeclarations([
		{ entryPath: "test/public.ms", entrySource: `
import { hidden } from "./model";
export function expose() { return hidden(); }
` },
		{ entryPath: "test/model.ms", entrySource: `
interface Hidden { value: int32; }
export function hidden(): Hidden { return { value: 1 }; }
` },
	], "test/public.ms");
	assert result.files.length == 0;
	assert result.diagnostics.length > 0;
	assert result.diagnostics[0].message.contains("not exported");
	assert result.diagnostics[0].sourcePath.endsWith("/test/public.ms");
}

test "declarations preserve class own visibility readonly and parameter properties" {
	const result = declarationOf(`
export class Record {
	private secret: int32 = 0;
	protected count: int32 = 1;
	constructor(public readonly title: string) {}
	private hidden(): int32 { return this.secret; }
}
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	const text = result.files[0].text;
	assert text.contains("private \"secret\": number;");
	assert text.contains("protected \"count\": number;");
	assert text.contains("public readonly \"title\": string;");
	assert text.contains("private \"hidden\";");
	assert !text.contains("hidden\"(");
}

test "declarations class inheritance closes value capable base import" {
	const result = graphDeclarations([
		{ entryPath: "class/child.ms", entrySource: `
import { Base } from "./base";
export class Child extends Base {
	own: string = "child";
	constructor(value: int32) { super(value); }
}
` },
		{ entryPath: "class/base.ms", entrySource: `
export class Base {
	value: int32 = 0;
	constructor(value: int32) { this.value = value; }
}
` },
	], "class/child.ms");
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files.length == 2;
	const text = result.files[0].text;
	assert text.contains("import { Base as __declarationType0 }");
	assert text.contains("class Child extends __declarationType0");
	assert text.contains("\"own\": string;");
	assert !text.contains("\"value\":");
}

test "declarations class omitted argument ABI remains explicitly pending" {
	const sources = [
		"export class DefaultCtor { constructor(value: int32 = 7) {} }",
		"export class OptionalCtor { constructor(value?: string) {} }",
		"export class DefaultMethod { constructor() {} read(value: int32 = 7) { return value; } }",
		"export class OptionalMethod { constructor() {} read(value?: string) { return value; } }",
	];
	for (const source of sources) {
		const result = declarationOf(source);
		assert result.files.length == 0;
		assert declarationMessages(result).contains("optional/default parameter");
		assert declarationMessages(result).contains("omitted-argument ABI");
	}
}

test "declarations class rest spread ABI remains explicitly pending" {
	for (const source of [
		"export class RestCtor { constructor(...values: int32[]) {} }",
		"export class RestMethod { constructor() {} read(...values: int32[]): int32 { return 1; } }",
	]) {
		const result = declarationOf(source);
		assert result.files.length == 0;
		assert declarationMessages(result).contains("rest parameter");
		assert declarationMessages(result).contains("spread ABI");
	}
}

test "declarations generic class constructor remains explicitly pending" {
	const result = declarationOf("export class Box<T> { value: T; constructor(value: T) { this.value = value; } }");
	assert result.files.length == 0;
	assert declarationMessages(result).contains("universal host-callable JS constructor");
}

test "declarations class static and accessor public members are never fictional" {
	for (const source of [
		"export class StaticMethod { constructor() {} static read(): int32 { return 1; } }",
		"export class StaticField { static readonly value: int32 = 1; constructor() {} }",
		"export class Accessor { constructor() {} get value(): int32 { return 1; } }",
	]) {
		const result = declarationOf(source);
		assert result.files.length == 0;
		assert declarationMessages(result).contains("no verified");
	}
}

test "declarations implicit and synthesized inherited constructors remain pending" {
	for (const source of [
		"export class Implicit { value: int32 = 1; }",
		"class Base { constructor(value: int32) {} } export class Inherited extends Base {}",
	]) {
		const result = declarationOf(source);
		assert result.files.length == 0;
		assert declarationMessages(result).contains("constructor");
		assert declarationMessages(result).contains("verified JS host construction");
	}
}

test "declarations class callbacks reject inline optional raw host ABI" {
	const result = declarationOf(`
export class InlineCallback {
	constructor(callback: (value?: int32) => int32) {}
}
`);
	assert result.files.length == 0;
	assert declarationMessages(result).contains("unsupported raw JS callback calling convention");
	assert declarationMessages(result).contains("pending host adaptation");
}

test "declarations class callbacks inspect aliases nested arrays and recursive shapes" {
	const result = declarationOf(`
type Callback = (...values: int32[]) => int32;
interface Callbacks { values: Callback[]; next: Callbacks | null; }
export class NestedCallbacks { constructor(callbacks: Callbacks) {} }
`);
	assert result.files.length == 0;
	assert declarationMessages(result).contains("raw JS callback calling convention");
}

test "declarations class callbacks inspect public fields and returned functions" {
	for (const source of [
		`type Callback = (value?: int32) => int32;
export class FieldCallback {
	callback: Callback | null = null;
	constructor() {}
}`,
		`type Callback = (value?: int32) => int32;
export class ReturnedCallback {
	constructor() {}
	read(): Callback { return (value?: int32): int32 => 1; }
}`,
	]) {
		const result = declarationOf(source);
		assert result.files.length == 0;
		assert declarationMessages(result).contains("raw JS callback calling convention");
	}
}

test "declarations class callbacks allow required signatures and erase private methods" {
	const result = declarationOf(`
type Callback = (value: int32) => int32;
interface Callbacks { values: Callback[]; next: Callbacks | null; }
export class RequiredCallbacks {
	constructor(callbacks: Callbacks) {}
	apply(value: int32, callback: Callback): int32 { return callback(value); }
	private hidden(callback: (value?: int32) => int32): int32 { return 1; }
}
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	assert result.files[0].text.contains("callback: Callback");
	assert result.files[0].text.contains("private \"hidden\";");
}

test "declarations serialize checked generic defaults on aliases interfaces and structs" {
	const result = declarationOf(`
export type Pair<T extends string = string, U = T[], V = [T, U]> = [T, U, V];
export interface Box<T = string, U = T[]> { value: T; values: U; }
export struct Cell<T = int32> { value: T; }
`);
	assert result.diagnostics.length == 0, declarationMessages(result);
	const text = result.files[0].text;
	assert text.contains("Pair<T extends string = string, U = Array<T>, V = [T, U]>"), text;
	assert text.contains("Box<T = string, U = Array<T>>"), text;
	assert text.contains("Cell<T = number>"), text;
}

test "declarations refuse written defaults missing their checked slot" {
	for (const source of [
		"export type Missing<T = string> = T;",
		"export interface Missing<T = string> { value: T; }",
	]) {
		const result = declarationOf(source, "Missing");
		assert result.files.length == 0;
		assert result.diagnostics.length > 0;
		assert result.diagnostics[0].sourcePath == "api.ms";
		assert result.diagnostics[0].line == 1;
		assert declarationMessages(result).contains("default");
		assert declarationMessages(result).contains("T");
	}
}
