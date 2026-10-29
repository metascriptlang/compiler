import { SymbolKind } from "../../ast/node";
import { ExportedSymInfo } from "../../checker/context";
import { ImportEntry } from "../../module/graph";


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
