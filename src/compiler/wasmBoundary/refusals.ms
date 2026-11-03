import { ImportEntry } from "../../module/graph";
import {
	Node,
	NodeKind,
	Symbol,
	MemberExprData,
	ProgramData,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { PEEL_ALIAS, peelThrough, typeDisplayName } from "../../checker/types";
import { BoundaryRefusal, handleTarget, isHandleType } from "./manifest";

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

function isHandleRead(node: Node, handles: Symbol[]): boolean {
	if (node.kind != NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	if (d.property != "value" && d.property != "take" && d.property != "ptr") {
		return false;
	}
	const t = d.object.nodeType;
	if (t == null) return false;
	const handle = peelThrough(t!, PEEL_ALIAS);
	if (handle == null || !isHandleType(handle!)) return false;
	const target = handleTarget(handle!);
	return target != null && target!.sym != null && handles.includes(target!.sym!);
}

function handleReadsIn(
	path: string,
	node: Node,
	handles: Symbol[],
	inWasm: Node[],
	errors: BoundaryRefusal[],
): void {
	if (inWasm.includes(node)) return;
	if (isHandleRead(node, handles)) {
		const d = node.data as MemberExprData;
		const shown = typeDisplayName(d.object.nodeType!);
		const at = node.location;
		errors.push({
			file: path,
			code: "handle-read",
			message: `${shown} reads a wasm-owned handle: `
				+ "pass it to a @wasm function",
			line: at.line,
			column: at.column,
			endLine: at.line,
			endColumn: at.column,
		});
	}
	forEachChild(node, (child: Node): void => {
		handleReadsIn(path, child, handles, inWasm, errors);
	});
}

export function placedHandleReadErrors(
	handles: Symbol[],
	path: string,
	program: Node,
	inWasm: Node[],
): BoundaryRefusal[] {
	const errors: BoundaryRefusal[] = [];
	if (handles.length == 0) return errors;
	for (const stmt of (program.data as ProgramData).programStmts) {
		handleReadsIn(path, stmt, handles, inWasm, errors);
	}
	return errors;
}
