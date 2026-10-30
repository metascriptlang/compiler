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

function exportsOf(names: string[]): ExportedSymInfo[] {
	const ctx = checkSource(SOURCE);
	if (ctx == null) throw new Error("internal: test source did not check");
	const exps: ExportedSymInfo[] = [];
	for (const n of names) {
		const sym = lookupSymbol(ctx.table, n);
		if (sym == null) throw new Error("internal: test source lacks " + n);
		exps.push(buildExportInfo(sym!, null as unknown as ExtensionRegistry, "/p/calc.ms", null as unknown as CheckerContext));
	}
	return exps;
}

function importOf(names: string[]): ImportEntry {
	return { names, aliases: names, sourcePath: "/p/calc.ms", sourceSpecifier: "./calc", dynamic: false, typeOnly: false };
}

test "a string parameter and a string result cross without a manifest error" {
	const m = manifestFor("/p/calc.ms", "/p/app.ms", exportsOf(["greet", "label", "add"]), ["greet", "label", "add"]);
	assert m.errors.length == 0;
	assert m.functions.length == 3;
}

test "the entry module and a lazily imported module cannot be placed" {
	const lazy = new HashSet<string>();
	assert placedModuleErrors(["/p/calc.ms"], "/p/app.ms", lazy).length == 0;
	const entry = placedModuleErrors(["/p/app.ms"], "/p/app.ms", lazy);
	assert entry.length == 1;
	assert entry[0].includes("'/p/app.ms' is the entry module");
	lazy.add("/p/calc.ms");
	const lazyErrors = placedModuleErrors(["/p/calc.ms"], "/p/app.ms", lazy);
	assert lazyErrors.length == 1;
	assert lazyErrors[0].includes("'/p/calc.ms' has @wasm functions but is loaded lazily");
}

test "an importer of a module with @wasm functions imports by name, a class included" {
	assert placedImportErrors("/p/app.ms", [importOf(["add", "Counter"])], ["/p/calc.ms"]).length == 0;
	const ns = placedImportErrors("/p/app.ms", [importOf(["*"])], ["/p/calc.ms"]);
	assert ns.length == 1;
	assert ns[0].includes("namespace import");
	assert placedImportErrors("/p/app.ms", [importOf(["*"])], ["/p/other.ms"]).length == 0;
}
