// JavaScript Codegen — Emit Helpers
//
// JSGenerator context, low-level emit functions.
// emitNode delegates to registered callback (set by jsgen.ms) to break circular imports.

import { Node, NodeKind, TypeKind, BlockStmtData } from "../../ast/node";
import { JsImportEntry } from "../../checker/context";


// ===== JS Generator =====

export class JSGenerator {
	buf: string[];
	indentLevel: number;
	jsImports: JsImportEntry[];
	bundleMode: boolean;
	bundleIsPrelude: boolean; // true if current module is std/core/* (global scope, skip imports)
	exportedNames: string[];
	importedNames: string[]; // track const-destructured names to avoid redeclaration in IIFEs
	// Maps import source specifier → resolved module ID for __mod["id"] lookups
	importSourceToModuleId: string[];
	importSourceToModuleIdKeys: string[];
	thisName: string;
	jsBigInt64: boolean;
	staticSlots: string[]; // module-scope storage for `static` decls written inside bodies
	// Multi-file emit (one ES module per source module). Names derive from the
	// export surface, imports derive from actual references — source import
	// statements only contribute side-effect ordering.
	multiFile: boolean;
	currentModulePath: string;
	importSpecKeys: string[];   // source import specifier → emitted specifier
	importSpecVals: string[];
	moduleSpecKeys: string[];   // absolute module path → emitted specifier
	moduleSpecVals: string[];
	modExportKeys: string[];    // absolute module path → source-level export names
	modExportVals: string[][];
	neededModules: string[];    // cross-module references collected during emission
	neededNames: string[][];
	isTestBuild: boolean;
	testNames: string[];        // parallel with testFuncs: declared name → wrapper fn
	testFuncs: string[];
	// Statement-level `/* line N:C "path" */` markers; sourcemap.ms reads them
	// back out of the finished text to build the mapping.
	lineDir: boolean;
	sourceFile: string;
	lastDirLine: int32;
	lastDirColumn: int32;
}

export function createJSGenerator(): JSGenerator {
	return { buf: [], indentLevel: 0, jsImports: [], bundleMode: false, bundleIsPrelude: false, exportedNames: [], importedNames: [], importSourceToModuleId: [], importSourceToModuleIdKeys: [], thisName: "this", jsBigInt64: false, staticSlots: [],
		multiFile: false, currentModulePath: "", importSpecKeys: [], importSpecVals: [], moduleSpecKeys: [], moduleSpecVals: [], modExportKeys: [], modExportVals: [], neededModules: [], neededNames: [],
		isTestBuild: false, testNames: [], testFuncs: [],
		lineDir: false, sourceFile: "", lastDirLine: 0 as int32, lastDirColumn: -1 as int32 };
}

export function recordNeededImport(gen: JSGenerator, modulePath: string, name: string): void {
	for (let i = 0; i < gen.neededModules.length; i += 1) {
		if (gen.neededModules[i] === modulePath) {
			for (const n of gen.neededNames[i]) { if (n === name) return; }
			gen.neededNames[i].push(name);
			return;
		}
	}
	gen.neededModules.push(modulePath);
	gen.neededNames.push([name]);
}

export function lookupImportSpec(gen: JSGenerator, specifier: string): string {
	for (let i = 0; i < gen.importSpecKeys.length; i += 1) {
		if (gen.importSpecKeys[i] === specifier) return gen.importSpecVals[i];
	}
	return "";
}

export function lookupModuleSpec(gen: JSGenerator, modulePath: string): string {
	for (let i = 0; i < gen.moduleSpecKeys.length; i += 1) {
		if (gen.moduleSpecKeys[i] === modulePath) return gen.moduleSpecVals[i];
	}
	return "";
}

export function moduleExportsName(gen: JSGenerator, modulePath: string, name: string): boolean {
	for (let i = 0; i < gen.modExportKeys.length; i += 1) {
		if (gen.modExportKeys[i] === modulePath) {
			for (const n of gen.modExportVals[i]) { if (n === name) return true; }
			return false;
		}
	}
	return false;
}

// ===== Typed Array Mapping (reference: arrayTypeForElemType) =====

export function jsTypedArrayName(elemKind: TypeKind, bigInt64: boolean): string {
	return match (elemKind) {
		TypeKind.Int8 => "Int8Array",
		TypeKind.Int16 => "Int16Array",
		TypeKind.Int32 => "Int32Array",
		TypeKind.Int64 => bigInt64 ? "BigInt64Array" : "",
		TypeKind.Uint8 | TypeKind.Char | TypeKind.Boolean => "Uint8Array",
		TypeKind.Uint16 => "Uint16Array",
		TypeKind.Uint32 => "Uint32Array",
		TypeKind.Uint64 => bigInt64 ? "BigUint64Array" : "",
		TypeKind.Float32 => "Float32Array",
		TypeKind.Float64 | TypeKind.Number => "Float64Array",
		_ => "",
	};
}

// ===== Callback Registration (breaks circular imports) =====

type EmitNodeFn = (gen: JSGenerator, node: Node) => void;

let emitNodeFn: EmitNodeFn = (gen: JSGenerator, node: Node): void => {};

export function registerEmitNode(fn: EmitNodeFn): void {
	emitNodeFn = fn;
}

export function emitNode(gen: JSGenerator, node: Node): void {
	emitNodeFn(gen, node);
}

// ===== Emit Helpers =====

export function emit(gen: JSGenerator, text: string): void {
	gen.buf.push(text);
}

export function emitIndent(gen: JSGenerator): void {
	for (let i = 0; i < gen.indentLevel; i += 1) {
		emit(gen, "  ");
	}
}

export function emitLine(gen: JSGenerator, text: string): void {
	emitIndent(gen);
	emit(gen, text);
	emit(gen, "\n");
}

export function emitNewline(gen: JSGenerator): void {
	emit(gen, "\n");
}

// Must own its line: the map parser reads a marker only when it is the whole
// line, and treats every following line as belonging to the same source line.
export function emitLineDir(gen: JSGenerator, node: Node): void {
	if (!gen.lineDir) return;
	if (node === null || node.location === null) return;
	const line = node.location.line;
	const column = node.location.column;
	if (line <= 0) return;
	// A repeat of the exact same position leaves the parser in the state it is
	// already in, so the marker would only add noise.
	if (line === gen.lastDirLine && column === gen.lastDirColumn) return;
	gen.lastDirLine = line;
	gen.lastDirColumn = column;
	emitIndent(gen);
	emit(gen, `/* line ${line.toString()}:${column.toString()} "${escapeJSString(gen.sourceFile)}" */\n`);
}

// ===== Composite Emit Helpers =====

export function emitJoinedStrings(gen: JSGenerator, items: string[], sep: string): void {
	if (items.length === 0) return;
	emit(gen, items[0]);
	for (let i = 1; i < items.length; i += 1) {
		emit(gen, sep);
		emit(gen, items[i]);
	}
}

// Like emitJoinedStrings but applies safeJsName to each item (for parameter names).
export type SafeNameFn = (name: string) => string;
export function emitJoinedSafeStrings(gen: JSGenerator, items: string[], sep: string, safeFn: SafeNameFn): void {
	if (items.length === 0) return;
	emit(gen, safeFn(items[0]));
	for (let i = 1; i < items.length; i += 1) {
		emit(gen, sep);
		emit(gen, safeFn(items[i]));
	}
}

export function emitJoinedNodes(gen: JSGenerator, items: Node[], sep: string): void {
	if (items.length === 0) return;
	emitNode(gen, items[0]);
	for (let i = 1; i < items.length; i += 1) {
		emit(gen, sep);
		emitNode(gen, items[i]);
	}
}

// Emit block content without indent prefix (for use after if/while/etc.)
export function emitBlockInline(gen: JSGenerator, node: Node): void {
	const d = node.data as BlockStmtData;
	emit(gen, "{\n");
	gen.indentLevel = gen.indentLevel + 1;
	for (const stmt of d.statements) {
		emitNode(gen, stmt);
	}
	gen.indentLevel = gen.indentLevel - 1;
	emitIndent(gen);
	emit(gen, "}");
}

// Emit block content or wrap single statement in block
export function emitBlockOrStmt(gen: JSGenerator, node: Node): void {
	if (node.kind === NodeKind.BlockStmt) {
		emitBlockInline(gen, node);
	} else {
		emit(gen, "{\n");
		gen.indentLevel = gen.indentLevel + 1;
		emitNode(gen, node);
		gen.indentLevel = gen.indentLevel - 1;
		emitIndent(gen);
		emit(gen, "}");
	}
}

// Emit function/method body or empty block
export function emitBodyOrEmpty(gen: JSGenerator, body: Node): void {
	if (body === null) {
		emit(gen, "{}");
	} else {
		emitBlockOrStmt(gen, body);
	}
}

// ===== Finalize =====

export function finalize(gen: JSGenerator): string {
	let result = "";
	for (const slot of gen.staticSlots) {
		result = result + slot;
	}
	for (const chunk of gen.buf) {
		result = result + chunk;
	}
	return result;
}

// ===== String Escaping =====

// BYTE-PURE walk (same rule as escapeCString): a UTF-16-unit walk splits astral
// chars into lone-surrogate halves whose WTF-8 bytes are invalid UTF-8 in the
// output file. Plain bytes are copied in RUNS so multi-byte sequences stay
// intact; real lone surrogates (WTF-8 ED A0-BF ..) become \uXXXX escapes.
export function escapeJSString(s: string): string {
	let result = "";
	let runStart = 0;
	let i = 0;
	while (i < s.byteLength) {
		const b = s.byteAt(i);
		if (b === "\\".code || b === "\"".code || b === "\n".code
				|| b === "\r".code || b === "\t".code || b === 0) {
			if (runStart < i) result = result + s.byteSlice(runStart, i);
			result = result + match (b) {
				"\\".code => "\\\\",
				"\"".code => "\\\"",
				"\n".code => "\\n",
				"\r".code => "\\r",
				"\t".code => "\\t",
				_ => "\\x00",
			};
			i += 1;
			runStart = i;
		} else if (b === 237 && i + 2 < s.byteLength
				&& s.byteAt(i + 1) >= 160 && s.byteAt(i + 1) <= 191) {
			if (runStart < i) result = result + s.byteSlice(runStart, i);
			const cu = 53248 + (s.byteAt(i + 1) - 128) * 64 + (s.byteAt(i + 2) - 128);
			result = result + "\\u" + cu.toString(16).padStart(4, "0");
			i += 3;
			runStart = i;
		} else {
			i += 1;
		}
	}
	if (runStart < i) result = result + s.byteSlice(runStart, i);
	return result;
}

// ===== Import Path Conversion =====

export function convertImportPath(path: string): string {
	if (path.length >= 3) {
		const suffix = path.slice(path.length - 3, path.length);
		if (suffix === ".ms") {
			return path.slice(0, path.length - 3) + ".js";
		}
	}
	return path;
}

// ===== Tests =====
test "StringBuf accumulation" {
	const gen = createJSGenerator();
	emit(gen, "hello");
	emit(gen, " ");
	emit(gen, "world");
	assert finalize(gen) === "hello world";
}

test "indentation" {
	const gen = createJSGenerator();
	gen.indentLevel = 2;
	emitIndent(gen);
	emit(gen, "x");
	assert finalize(gen) === "    x";
}

test "emitLine" {
	const gen = createJSGenerator();
	emitLine(gen, "const x = 1;");
	assert finalize(gen) === "const x = 1;\n";
}

test "escapeJSString basics" {
	assert escapeJSString("hello") === "hello";
	assert escapeJSString("a\\b") === "a\\\\b";
}

test "escapeJSString keeps astral runs, escapes lone surrogates" {
	const astral = fromCodePoint(128512);
	assert escapeJSString(astral) === astral;
	assert escapeJSString(fromCodePoint(55296)) === "\\" + "ud800";
	assert escapeJSString(fromCodePoint(57343)) === "\\" + "udfff";
}

test "convertImportPath" {
	assert convertImportPath("./module.ms") === "./module.js";
	assert convertImportPath("./module") === "./module";
	assert convertImportPath("std/testing") === "std/testing";
}
