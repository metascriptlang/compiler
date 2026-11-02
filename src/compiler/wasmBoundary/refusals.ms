import { ImportEntry } from "../../module/graph";
import { BoundaryRefusal } from "./manifest";

function unlocated(
	file: string,
	code: string,
	message: string,
): BoundaryRefusal {
	return { file, code, message, line: 0, column: 0, endLine: 0, endColumn: 0 };
}

export function placedModuleErrors(
	placed: string[],
	entryPath: string,
	lazy: HashSet<string>,
): BoundaryRefusal[] {
	const errors: BoundaryRefusal[] = [];
	for (const path of placed) {
		if (path == entryPath) {
			const message = `'${path}' is the entry module and has @wasm functions: `
				+ "the entry's top-level code would run again in wasm, "
				+ "so move them into a module it imports";
			errors.push(unlocated(path, "entry-module", message));
		}
		if (lazy.has(path)) {
			const message = `'${path}' has @wasm functions but is loaded lazily `
				+ "with import(): a module with @wasm functions must be imported "
				+ "statically";
			errors.push(unlocated(path, "lazy-module", message));
		}
	}
	return errors;
}

export function placedImportErrors(
	importerPath: string,
	imports: ImportEntry[],
	placed: string[],
): BoundaryRefusal[] {
	const errors: BoundaryRefusal[] = [];
	for (const imp of imports) {
		if (!placed.includes(imp.sourcePath) || !imp.names.includes("*")) continue;
		const message = `'${importerPath}' imports '*' from '${imp.sourcePath}', `
			+ "which has @wasm functions: a namespace import is not supported "
			+ "there, import the functions by name";
		errors.push(unlocated(importerPath, "namespace-import", message));
	}
	return errors;
}
