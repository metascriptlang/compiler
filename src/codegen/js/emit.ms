// JavaScript Codegen — Emit Helpers
//
// JSGenerator context, low-level emit functions.
// emitNode delegates to registered callback (set by jsgen.ms) to break circular imports.

import { Node, NodeKind, TypeKind, BlockStmtData } from "../../ast/node";
import { JsImportEntry } from "../../checker/context";
import { SourceInfo, createSourceInfo, recordSegment, internFile, internName, shiftLines } from "./sourcemap";


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
	// Source map v3, recorded as the text is written.
	smap: boolean;
	sourceFile: string;
	smapInfo: SourceInfo;
	genLine: int32;           // 0-indexed line in the emitted JS
	genCol: int32;            // 0-indexed UTF-16 column, what the spec counts
	// A mark waits for the next non-blank byte, so indentation and separators
	// never take the position that belongs to the token.
	pendingLine: int32;       // 1-based .ms line, 0 = nothing pending
	pendingCol: int32;
	pendingName: int32;
}

export function createJSGenerator(): JSGenerator {
	return { buf: [], indentLevel: 0, jsImports: [], bundleMode: false, bundleIsPrelude: false, exportedNames: [], importedNames: [], importSourceToModuleId: [], importSourceToModuleIdKeys: [], thisName: "this", staticSlots: [],
		multiFile: false, currentModulePath: "", importSpecKeys: [], importSpecVals: [], moduleSpecKeys: [], moduleSpecVals: [], modExportKeys: [], modExportVals: [], neededModules: [], neededNames: [],
		isTestBuild: false, testNames: [], testFuncs: [],
		smap: false, sourceFile: "", smapInfo: createSourceInfo(),
		genLine: 0 as int32, genCol: 0 as int32,
		pendingLine: 0 as int32, pendingCol: 0 as int32, pendingName: -1 as int32 };
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

export function jsTypedArrayName(elemKind: TypeKind): string {
	return match (elemKind) {
		TypeKind.Int8 => "Int8Array",
		TypeKind.Int16 => "Int16Array",
		TypeKind.Int32 => "Int32Array",
		TypeKind.Int64 => "BigInt64Array",
		TypeKind.Uint8 | TypeKind.Char | TypeKind.Boolean => "Uint8Array",
		TypeKind.Uint16 => "Uint16Array",
		TypeKind.Uint32 => "Uint32Array",
		TypeKind.Uint64 => "BigUint64Array",
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

// Lexer positions count from 1 on both axes; the map counts from 0 on both.
function flushPending(gen: JSGenerator): void {
	recordSegment(gen.smapInfo, gen.genLine, gen.genCol,
		internFile(gen.smapInfo, gen.sourceFile),
		(gen.pendingLine - 1) as int32, (gen.pendingCol - 1) as int32, gen.pendingName);
	gen.pendingLine = 0 as int32;
	gen.pendingName = -1 as int32;
}

// Source map columns count UTF-16 units, so a byte walk has to widen astral
// characters to the surrogate pair a debugger will see.
function advance(gen: JSGenerator, text: string): void {
	let i: int32 = 0;
	while (i < text.byteLength) {
		const b = text.byteAt(i);
		if (b === "\n".code) {
			gen.genLine += 1;
			gen.genCol = 0 as int32;
			i += 1;
		} else {
			if (gen.pendingLine > 0 && b !== " ".code && b !== "\t".code && b !== "\r".code) {
				flushPending(gen);
			}
			if (b < 128) { gen.genCol += 1; i += 1; }
			else if (b < 224) { gen.genCol += 1; i += 2; }
			else if (b < 240) { gen.genCol += 1; i += 3; }
			else { gen.genCol += 2; i += 4; }
		}
	}
}

export function emit(gen: JSGenerator, text: string): void {
	gen.buf.push(text);
	if (gen.smap) advance(gen, text);
}

// Claims the next token emitted for `node`. A node that emits nothing of its
// own is overwritten by the child it delegates to, which is the better answer.
export function mark(gen: JSGenerator, node: Node): void {
	if (!gen.smap) return;
	if (node === null || node.location === null) return;
	// A synthetic node carries no column. Leaving the enclosing node's mark in
	// place points at real code instead of at the start of the line.
	if (node.location.line <= 0 || node.location.column <= 0) return;
	gen.pendingLine = node.location.line;
	gen.pendingCol = node.location.column;
	gen.pendingName = -1 as int32;
}

// Same as mark, plus the .ms name this token was renamed from.
export function markNamed(gen: JSGenerator, node: Node, original: string): void {
	if (!gen.smap) return;
	mark(gen, node);
	if (gen.pendingLine === 0 || original === "") return;
	gen.pendingName = internName(gen.smapInfo, original);
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

// Params carry no own location in the AST, so the declaration's position is
// the closest honest origin; the name still lets a debugger un-rename them.
export function emitJoinedSafeParams(gen: JSGenerator, declNode: Node, items: string[], sep: string, safeFn: SafeNameFn): void {
	if (items.length === 0) return;
	markNamed(gen, declNode, items[0]);
	emit(gen, safeFn(items[0]));
	for (let i = 1; i < items.length; i += 1) {
		emit(gen, sep);
		markNamed(gen, declNode, items[i]);
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

// The static slots go in front of everything the emitters wrote, so every
// position recorded during emission owes them their line count.
export function finalize(gen: JSGenerator): string {
	let result = "";
	let slotLines: int32 = 0;
	for (const slot of gen.staticSlots) {
		result = result + slot;
		if (gen.smap) {
			for (let i: int32 = 0; i < slot.byteLength; i += 1) {
				if (slot.byteAt(i) === "\n".code) slotLines += 1;
			}
		}
	}
	if (gen.smap) shiftLines(gen.smapInfo, slotLines);
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
