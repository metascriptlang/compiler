import { ImportEntry } from "../../module/graph";
import { BoundaryRefusal } from "./manifest";

function unlocated(file: string, code: string, message: string): BoundaryRefusal {
	return { file, code, message, line: 0, column: 0, endLine: 0, endColumn: 0 };
}

export function placedModuleErrors(placed: string[], entryPath: string, lazy: HashSet<string>): BoundaryRefusal[] {
	const errors: BoundaryRefusal[] = [];
	for (const path of placed) {
		if (path == entryPath) errors.push(unlocated(path, "entry-module", `'${path}' is the entry module and has @wasm functions: the entry's top-level code would run again in wasm, so move them into a module it imports`));
		if (lazy.has(path)) errors.push(unlocated(path, "lazy-module", `'${path}' has @wasm functions but is loaded lazily with import(): a module with @wasm functions must be imported statically`));
	}
	return errors;
}

export function placedImportErrors(importerPath: string, imports: ImportEntry[], placed: string[]): BoundaryRefusal[] {
	const errors: BoundaryRefusal[] = [];
	for (const imp of imports) {
		if (!placed.includes(imp.sourcePath) || !imp.names.includes("*")) continue;
		errors.push(unlocated(importerPath, "namespace-import", `'${importerPath}' imports '*' from '${imp.sourcePath}', which has @wasm functions: a namespace import is not supported there, import the functions by name`));
	}
	return errors;
}
