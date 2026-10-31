import { ExtensionRegistry, buildExportInfo, ExportedSymInfo, CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { ImportEntry } from "../../module/graph";
import { checkSource } from "../handoff/helpers";
import { manifestFor } from "../../compiler/wasmBoundary/manifest";
import { placedModuleErrors, placedImportErrors } from "../../compiler/wasmBoundary/refusals";

const SOURCE = `
export class Counter { value: int32 = 0; }
export function greet(name: string): int32 { return 1; }
export function label(n: int32): string { return "x"; }
export function add(a: int32, b: int32): int32 { return a + b; }
`;

function exportsFrom(source: string, names: string[]): ExportedSymInfo[] {
	const ctx = checkSource(source);
	if (ctx == null) throw new Error("internal: test source did not check");
	const exps: ExportedSymInfo[] = [];
	for (const n of names) {
		const sym = lookupSymbol(ctx.table, n);
		if (sym == null) throw new Error("internal: test source lacks " + n);
		exps.push(buildExportInfo(sym!, null as unknown as ExtensionRegistry, "/p/calc.ms", null as unknown as CheckerContext));
	}
	return exps;
}

function exportsOf(names: string[]): ExportedSymInfo[] {
	return exportsFrom(SOURCE, names);
}

function importOf(names: string[]): ImportEntry {
	return { names, aliases: names, sourcePath: "/p/calc.ms", sourceSpecifier: "./calc", dynamic: false, typeOnly: false };
}

test "a string parameter and a string result cross without a manifest error" {
	const m = manifestFor("/p/calc.ms", "/p/app.ms", exportsOf(["greet", "label", "add"]), ["greet", "label", "add"]);
	assert m.errors.length == 0, m.errors.map((e) => e.message).join("; ");
	assert m.functions.length == 3;
}

test "the entry module and a lazily imported module cannot be placed" {
	const lazy = new HashSet<string>();
	assert placedModuleErrors(["/p/calc.ms"], "/p/app.ms", lazy).length == 0;
	const entry = placedModuleErrors(["/p/app.ms"], "/p/app.ms", lazy);
	assert entry.length == 1;
	assert entry[0].message.includes("'/p/app.ms' is the entry module");
	assert entry[0].code == "entry-module" && entry[0].file == "/p/app.ms" && entry[0].line == 0;
	lazy.add("/p/calc.ms");
	const lazyErrors = placedModuleErrors(["/p/calc.ms"], "/p/app.ms", lazy);
	assert lazyErrors.length == 1;
	assert lazyErrors[0].message.includes("'/p/calc.ms' has @wasm functions but is loaded lazily");
	assert lazyErrors[0].code == "lazy-module" && lazyErrors[0].file == "/p/calc.ms";
}

test "an importer of a module with @wasm functions imports by name, a class included" {
	assert placedImportErrors("/p/app.ms", [importOf(["add", "Counter"])], ["/p/calc.ms"]).length == 0;
	const ns = placedImportErrors("/p/app.ms", [importOf(["*"])], ["/p/calc.ms"]);
	assert ns.length == 1;
	assert ns[0].message.includes("namespace import");
	assert ns[0].code == "namespace-import" && ns[0].file == "/p/app.ms";
	assert placedImportErrors("/p/app.ms", [importOf(["*"])], ["/p/other.ms"]).length == 0;
}

const REFUSED = `
class Box { v: int32 = 0; }
export function takesBox(b: Box): int32 { return 0; }
export function wide(): Box { return new Box(); }
export function cbRows(cb: (rows: string[]) => void): void {}
export function pair<T>(x: T): T { return x; }
export function takesArray(xs: int32[]): int32 { return 0; }
export function view(xs: Span<int32>): Span<int32> { return xs; }
`;

test "a refusal carries its file, a code and the position of the annotation it refuses" {
	const names = ["takesBox", "wide", "cbRows", "pair", "takesArray", "view"];
	const m = manifestFor("/p/calc.ms", "/p/app.ms", exportsFrom(REFUSED, names), names);
	assert m.functions.length == 0;
	assert m.errors.length == 6, m.errors.map((e) => e.message).join("; ");
	for (const e of m.errors) assert e.file == "/p/calc.ms" && e.line > 0 && e.column > 0, e.message;
	const takesBox = m.errors[0];
	assert takesBox.code == "no-form" && takesBox.line == 3 && takesBox.column == 29, `${takesBox.code} ${takesBox.line}:${takesBox.column}`;
	assert takesBox.endLine == 3 && takesBox.endColumn > takesBox.column;
	const wide = m.errors[1];
	assert wide.code == "no-form" && wide.line == 4 && wide.column == 25, `${wide.code} ${wide.line}:${wide.column}`;
	const cbRows = m.errors[2];
	assert cbRows.code == "callback-param" && cbRows.line == 5 && cbRows.column == 28, `${cbRows.code} ${cbRows.line}:${cbRows.column}`;
	const pair = m.errors[3];
	assert pair.code == "generic" && pair.line == 6 && pair.column == 17, `${pair.code} ${pair.line}:${pair.column}`;
	const takesArray = m.errors[4];
	assert takesArray.line == 7 && takesArray.column >= 32 && takesArray.column <= 37, `${takesArray.code} ${takesArray.line}:${takesArray.column}`;
	const view = m.errors[5];
	assert view.code == "span-result" && view.line == 8 && view.column == 40, `${view.code} ${view.line}:${view.column}`;
}
