import { ImportEntry } from "../../module/graph";


export function placedModuleErrors(placed: string[], entryPath: string, lazy: HashSet<string>): string[] {
	const errors: string[] = [];
	for (const path of placed) {
		if (path == entryPath) errors.push(`'${path}' is the entry module and has @wasm functions: the entry's top-level code would run again in wasm, so move them into a module it imports`);
		if (lazy.has(path)) errors.push(`'${path}' has @wasm functions but is loaded lazily with import(): a module with @wasm functions must be imported statically`);
	}
	return errors;
}

export function placedImportErrors(importerPath: string, imports: ImportEntry[], placed: string[]): string[] {
	const errors: string[] = [];
	for (const imp of imports) {
		if (!placed.includes(imp.sourcePath) || !imp.names.includes("*")) continue;
		errors.push(`'${importerPath}' imports '*' from '${imp.sourcePath}', which has @wasm functions: a namespace import is not supported there, import the functions by name`);
	}
	return errors;
}
