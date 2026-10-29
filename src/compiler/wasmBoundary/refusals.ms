import { SymbolKind } from "../../ast/node";
import { ExportedSymInfo } from "../../checker/context";
import { ImportEntry } from "../../module/graph";
import { BoundaryFunction, BoundaryKind } from "./manifest";

const STRING_CROSSING = "string crossing the wasm boundary is not supported yet";

export function stringBoundaryErrors(fns: BoundaryFunction[]): string[] {
	const errors: string[] = [];
	for (const f of fns) {
		for (const p of f.params) {
			if (p.kind == BoundaryKind.String) errors.push(`'${f.name}' in '${f.modulePath}' cannot cross the JS/wasm boundary: parameter '${p.name}' is a string; ${STRING_CROSSING}`);
		}
		if (f.result == BoundaryKind.String) errors.push(`'${f.name}' in '${f.modulePath}' cannot cross the JS/wasm boundary: its result is a string; ${STRING_CROSSING}`);
	}
	return errors;
}

export function placedModuleErrors(placed: string[], entryPath: string, lazy: HashSet<string>): string[] {
	const errors: string[] = [];
	for (const path of placed) {
		if (path == entryPath) errors.push(`'${path}' is the entry module and carries @wasm();: the entry stays JS, so move the wasm part into a module it imports`);
		if (lazy.has(path)) errors.push(`'${path}' carries @wasm(); but is loaded lazily with import(): a wasm-placed module must be imported statically`);
	}
	return errors;
}

export function placedImportErrors(importerPath: string, imports: ImportEntry[], placed: string[], exportsOf: (modulePath: string) => ExportedSymInfo[]): string[] {
	const errors: string[] = [];
	for (const imp of imports) {
		if (!placed.includes(imp.sourcePath)) continue;
		const exports = exportsOf(imp.sourcePath);
		for (const name of imp.names) {
			if (name == "*") {
				errors.push(`'${importerPath}' imports '*' from the wasm-placed module '${imp.sourcePath}': a namespace import is not supported, import the functions by name`);
				continue;
			}
			for (const e of exports) {
				if (e.name == name && e.sym.symbolKind != SymbolKind.Function) {
					errors.push(`'${importerPath}' imports '${name}' from the wasm-placed module '${imp.sourcePath}': only functions cross the JS/wasm boundary`);
				}
			}
		}
	}
	return errors;
}
