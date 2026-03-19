// Module Loader — recursive module loading with cycle detection
//
// Loads modules depth-first, building a ModuleGraph with topological loadOrder.
// Uses SourceProvider abstraction for testability (MapProvider for tests,
// FileProvider for real I/O).
//
// Supports backend-aware resolution via ResolverConfig:
//   - Backend-specific extensions (.cms, .jms, .rms, .ems, .wms)
//   - std/ library resolution against configurable stdPath
//   - Multiple search paths for bare imports
//   - Path alias rewriting
//
// NOTE: ASTs are NOT stored on Module (DRC lifecycle mangling bug prevents
// storing Node on interfaces defined outside ast/node.ms). The loader parses
// temporarily to extract import declarations, then discards the AST.
// The checker re-parses Module.source for each pass.

import {
	Module, ModuleGraph, ModuleState, ImportEntry,
	createModuleGraph, createModule, createImportEntry,
	findModule, hasModule, addModule,
	isInImportStack, pushImportStack, popImportStack,
	createModuleError, ErrorSeverity,
} from "./graph";
import { resolveImport, resolveImportWithConfig, isStdImport, ResolverConfig } from "./resolver";
import { lex } from "../lexer/lexer";
import { createState } from "../parser/context";
import { callStateProgramParser } from "../parser/statements/callbacks";
import "../parser/statements/core";
import { Node, NodeKind, ProgramData, ImportDeclData, ExportDeclData } from "../ast/node";
import { readFile } from "std/process";
// (utils/string imports removed — using native .slice)

// ===== Source Provider =====

export interface MapEntry {
	entryPath: string;
	entrySource: string;
}

export class SourceProvider {
	entries: MapEntry[];
	useFileSystem: boolean;
}

export function createMapProvider(entries: MapEntry[]): SourceProvider {
	return { entries, useFileSystem: false };
}

export function createFileSystemProvider(): SourceProvider {
	return { entries: [], useFileSystem: true };
}

export function provideSource(provider: SourceProvider, path: string): Result<string, string> {
	for (const e of provider.entries) {
		if (e.entryPath === path) return Result.ok(e.entrySource);
	}
	if (provider.useFileSystem) {
		const content = readFile(path);
		if (content.length > 0) {
			const cached: MapEntry = { entryPath: path, entrySource: content };
			provider.entries.push(cached);
			return Result.ok(content);
		}
	}
	return Result.err(`File not found: ${path}`);
}

// ===== C Header Detection =====

// Inline .h imports: scan source for `import { ... } from "*.h"` lines,
// replace each with @include + extern declarations generated from the C header.
// reference parity: importc declarations live inline in the consuming module.
function inlineHeaderImports(source: string, modulePath: string, provider: SourceProvider): string {
	let result = source;
	let searchPos = 0;
	while (searchPos < result.length) {
		// Find next import statement
		const importIdx = result.indexOf("import ", searchPos);
		if (importIdx < 0) break;

		// Find the full import statement (may span multiple lines) — terminated by ;
		const stmtEnd = result.indexOf(";", importIdx);
		if (stmtEnd < 0) { searchPos = importIdx + 7; continue; }
		const stmt = result.slice(importIdx, stmtEnd + 1);

		// Check if it imports from a .h file
		const fromIdx = stmt.indexOf(" from ");
		if (fromIdx < 0) { searchPos = importIdx + 7; continue; }

		// Extract specifier (between quotes after "from")
		const afterFrom = stmt.slice(fromIdx + 6, stmt.length).trim();
		let specifier = "";
		if (afterFrom.startsWith("\"") || afterFrom.startsWith("'")) {
			const quote = afterFrom.charAt(0);
			const endQuote = afterFrom.indexOf(quote, 1);
			if (endQuote > 0) specifier = afterFrom.slice(1, endQuote);
		}

		if (!specifier.endsWith(".h")) { searchPos = importIdx + 7; continue; }

		// Resolve the .h file path relative to the consuming module
		let headerPath = specifier;
		if (specifier.startsWith("./") || specifier.startsWith("../")) {
			const moduleDir = modulePath.slice(0, modulePath.lastIndexOf("/"));
			headerPath = moduleDir + "/" + specifier.slice(specifier.startsWith("./") ? 2 : 0, specifier.length);
		}

		// Read the .h file
		const headerSource = provideSource(provider, headerPath);
		if (!headerSource.ok) { searchPos = importIdx + 7; continue; }

		// Extract import list: import { A, B, C } → ["A", "B", "C"]
		const importedNames: string[] = [];
		const braceOpen = stmt.indexOf("{");
		const braceClose = stmt.indexOf("}");
		if (braceOpen >= 0 && braceClose > braceOpen) {
			const importList = stmt.slice(braceOpen + 1, braceClose).split(",");
			for (const n of importList) {
				const trimmed = n.trim();
				if (trimmed.length > 0) importedNames.push(trimmed);
			}
		}

		// Generate extern declarations — only for symbols in importedNames
		let translated = translateCHeader(headerSource.value, importedNames);
		// Strip "export " prefix (inline declarations don't need export)
		translated = translated.split("export extern ").join("extern ");

		// Auto-compile companion .c file if it exists (e.g., native.h → native.c)
		const companionC = headerPath.slice(0, headerPath.length - 2) + ".c";
		const hasCompanionC = provideSource(provider, companionC).ok;
		let compileDirective = "";
		if (hasCompanionC) compileDirective = `@compile("${companionC}");\n`;

		// Build replacement: @include + @compile (if .c exists) + extern declarations
		const replacement = `@include("${headerPath}");\n${compileDirective}${translated}`;

		// Replace the import statement (may span multiple lines) with the inlined declarations
		const replaceStart = importIdx;
		const replaceEnd = stmtEnd + 1;
		// Skip trailing newline after semicolon if present
		const afterSemi = replaceEnd < result.length && result.charCodeAt(replaceEnd) === "\n".code ? replaceEnd + 1 : replaceEnd;
		result = result.slice(0, replaceStart) + replacement + result.slice(afterSemi, result.length);

		searchPos = replaceStart + replacement.length;
	}
	return result;
}

function isCHeaderPath(path: string): boolean {
	if (path.length < 3) return false;
	return path.slice(path.length - 2, path.length) === ".h";
}

// ===== C Header → MetaScript Translator =====
// Scans C header for typedef struct and function prototypes,
// generates equivalent MetaScript extern declarations.

function cTypeToMs(cType: string): string {
	const t = cType.trim();
	if (t.endsWith("*")) return "int64";
	return match (t) {
		"msString" | "const char*" | "char*" => "string",
		"int32_t" | "int" => "int32",
		"int64_t" | "long long" => "int64",
		"uint8_t" | "unsigned char" => "uint8",
		"uint16_t" => "uint16",
		"uint32_t" | "unsigned int" => "uint32",
		"uint64_t" => "uint64",
		"double" | "size_t" => "number",
		"float" => "float32",
		"void" => "void",
		"bool" | "_Bool" => "boolean",
		_ => t,
	};
}

export function translateCHeader(source: string, importedNames: string[]): string {
	let result = "";
	let resultLines = 1;  // current line count in result
	let pos = 0;
	let lastLinePos = 0;  // position up to which we've counted lines
	let lastLineNum = 1;  // line number at lastLinePos

	while (pos < source.length) {
		// Skip whitespace and comments
		while (pos < source.length && (source.charCodeAt(pos) <= 32)) pos = pos + 1;
		if (pos >= source.length) break;

		// Skip single-line comments
		if (pos + 1 < source.length && source.slice(pos, pos + 2) === "//") {
			while (pos < source.length && source.charCodeAt(pos) !== "\n".code) pos = pos + 1;
			continue;
		}
		// Skip block comments
		if (pos + 1 < source.length && source.slice(pos, pos + 2) === "/*") {
			pos = pos + 2;
			while (pos + 1 < source.length && source.slice(pos, pos + 2) !== "*/") pos = pos + 1;
			pos = pos + 2;
			continue;
		}
		// Skip preprocessor directives
		if (source.charCodeAt(pos) === "#".code) {
			while (pos < source.length && source.charCodeAt(pos) !== "\n".code) pos = pos + 1;
			continue;
		}

		// typedef struct { ... } Name;
		if (source.slice(pos, pos + 15) === "typedef struct ") {
			const braceStart = source.indexOf("{", pos);
			if (braceStart < 0) { pos = pos + 15; continue; }
			// Find matching closing brace
			let depth = 1;
			let braceEnd = braceStart + 1;
			while (braceEnd < source.length && depth > 0) {
				if (source.charCodeAt(braceEnd) === "{".code) depth = depth + 1;
				if (source.charCodeAt(braceEnd) === "}".code) depth = depth - 1;
				braceEnd = braceEnd + 1;
			}
			// Extract name after closing brace: } Name;
			let nameStart = braceEnd;
			while (nameStart < source.length && source.charCodeAt(nameStart) <= 32) nameStart = nameStart + 1;
			let nameEnd = nameStart;
			while (nameEnd < source.length && source.charCodeAt(nameEnd) > 32 && source.charCodeAt(nameEnd) !== ";".code) nameEnd = nameEnd + 1;
			const structName = source.slice(nameStart, nameEnd);

			if (structName.length > 0 && structName !== "{" && (importedNames.length === 0 || importedNames.indexOf(structName) >= 0)) {
				// Pad to preserve original line number (go-to-definition accuracy)
				while (lastLinePos < pos) { if (source.charCodeAt(lastLinePos) === "\n".code) lastLineNum = lastLineNum + 1; lastLinePos = lastLinePos + 1; }
				while (resultLines < lastLineNum) { result = result + "\n"; resultLines = resultLines + 1; }
				// Parse fields inside braces
				const fieldsStr = source.slice(braceStart + 1, braceEnd - 1).trim();
				result = result + `export extern struct ${structName} {\n`; resultLines = resultLines + 1;
				// Split by semicolons for fields
				let fPos = 0;
				while (fPos < fieldsStr.length) {
					// Skip whitespace
					while (fPos < fieldsStr.length && fieldsStr.charCodeAt(fPos) <= 32) fPos = fPos + 1;
					if (fPos >= fieldsStr.length) break;
					// Find semicolon
					const semi = fieldsStr.indexOf(";", fPos);
					if (semi < 0) break;
					const fieldDecl = fieldsStr.slice(fPos, semi).trim();
					if (fieldDecl.length > 0) {
						// Parse "type name" — last word is name, rest is type
						const lastSpace = fieldDecl.lastIndexOf(" ");
						if (lastSpace > 0) {
							const fType = fieldDecl.slice(0, lastSpace).trim();
							const fName = fieldDecl.slice(lastSpace + 1, fieldDecl.length).trim();
							result = result + `\t${fName}: ${cTypeToMs(fType)};\n`; resultLines = resultLines + 1;
						}
					}
					fPos = semi + 1;
				}
				result = result + "}\n\n"; resultLines = resultLines + 2;
			}
			// Skip past semicolon
			pos = source.indexOf(";", braceEnd);
			if (pos < 0) pos = source.length; else pos = pos + 1;
			continue;
		}

		// Function prototypes: returnType funcName(params);
		// Match: word+ word( ... );  but skip "static", "inline", "typedef", "#"
		const lineEnd = source.indexOf("\n", pos);
		const line = source.slice(pos, lineEnd >= 0 ? lineEnd : source.length).trim();
		// Strip static/inline/extern qualifiers for function matching
		let funcLine = line;
		if (funcLine.startsWith("static inline ")) funcLine = funcLine.slice(14, funcLine.length);
		else if (funcLine.startsWith("static ")) funcLine = funcLine.slice(7, funcLine.length);
		else if (funcLine.startsWith("inline ")) funcLine = funcLine.slice(7, funcLine.length);
		else if (funcLine.startsWith("extern ")) funcLine = funcLine.slice(7, funcLine.length);

		if (funcLine.length > 0 && !funcLine.startsWith("typedef")
			&& !funcLine.startsWith("#") && !funcLine.startsWith("extern \"C\"")
			&& !funcLine.startsWith("{") && !funcLine.startsWith("}")
			&& funcLine.indexOf("(") > 0 && (funcLine.endsWith(";") || funcLine.endsWith(") {"))) {
			// Function definition with body: skip the entire body
			const hasBody = funcLine.endsWith(") {") || line.endsWith(") {");
			if (hasBody) funcLine = funcLine.slice(0, funcLine.length - 2) + ";";
			// Parse: returnType funcName(param1Type param1Name, ...);
			const parenOpen = funcLine.indexOf("(");
			const parenClose = funcLine.lastIndexOf(")");
			if (parenOpen > 0 && parenClose > parenOpen) {
				const beforeParen = funcLine.slice(0, parenOpen).trim();
				const lastSp = beforeParen.lastIndexOf(" ");
				if (lastSp > 0) {
					const retType = beforeParen.slice(0, lastSp).trim();
					const funcName = beforeParen.slice(lastSp + 1, beforeParen.length).trim();
					const paramsStr = funcLine.slice(parenOpen + 1, parenClose).trim();

					if (funcName.length > 0 && funcName.charCodeAt(0) !== "*".code && (importedNames.length === 0 || importedNames.indexOf(funcName) >= 0)) {
						// Pad to preserve original line number
						while (lastLinePos < pos) { if (source.charCodeAt(lastLinePos) === "\n".code) lastLineNum = lastLineNum + 1; lastLinePos = lastLinePos + 1; }
						while (resultLines < lastLineNum) { result = result + "\n"; resultLines = resultLines + 1; }
						let msParams = "";
						if (paramsStr !== "void" && paramsStr.length > 0) {
							const params = paramsStr.split(",");
							let first = true;
							for (const p of params) {
								const param = p.trim();
								const pLastSp = param.lastIndexOf(" ");
								if (pLastSp > 0) {
									let pType = param.slice(0, pLastSp).trim();
									let pName = param.slice(pLastSp + 1, param.length).trim();
									// Handle pointer params: int32_t *name → name is *name
									if (pName.startsWith("*")) {
										pName = pName.slice(1, pName.length);
										pType = pType + "*";
									}
									if (!first) msParams = msParams + ", ";
									msParams = msParams + `${pName}: ${cTypeToMs(pType)}`;
									first = false;
								}
							}
						}
						result = result + `export extern function ${funcName}(${msParams}): ${cTypeToMs(retType)};\n`; resultLines = resultLines + 1;
					}
				}
			}
			// Skip function body: find matching closing brace
			if (hasBody) {
				let bodyDepth = 1;
				let bodyPos = source.indexOf("{", pos);
				if (bodyPos >= 0) {
					bodyPos = bodyPos + 1;
					while (bodyPos < source.length && bodyDepth > 0) {
						if (source.charCodeAt(bodyPos) === "{".code) bodyDepth = bodyDepth + 1;
						if (source.charCodeAt(bodyPos) === "}".code) bodyDepth = bodyDepth - 1;
						bodyPos = bodyPos + 1;
					}
					pos = bodyPos;
					continue;
				}
			}
		}
		pos = (lineEnd >= 0 ? lineEnd : source.length) + 1;
	}

	return result;
}

// ===== Module Loading =====

function finalizeModule(graph: ModuleGraph, mod: Module, path: string): void {
	popImportStack(graph);
	mod.state = ModuleState.Ready;
	graph.loadOrder.push(path);
}

// Helper: create module, add to graph, push import stack.
// Isolates Module* from caller's DRC scope (avoids premature msDecref).
function createAndAddModule(graph: ModuleGraph, path: string): void {
	const mod = createModule(path);
	mod.state = ModuleState.Loading;
	addModule(graph, mod);
	pushImportStack(graph, path);
}

// Load .ms source module — DRC-isolated (mod stays in this scope)
function loadSourceModule(graph: ModuleGraph, path: string, provider: SourceProvider, config: ResolverConfig, useConfig: number): boolean {
	const mod = createModule(path);
	mod.state = ModuleState.Loading;
	addModule(graph, mod);
	pushImportStack(graph, path);

	// Read source
	const sourceResult = provideSource(provider, path);
	if (!sourceResult.ok) {
		mod.errors.push(createModuleError(sourceResult.error, 0, 0, ErrorSeverity.Error));
		finalizeModule(graph, mod, path);
		return false;
	}
	mod.source = sourceResult.value;

	// Inline .h imports: replace `import { ... } from "*.h"` with extern declarations.
	// reference parity: importc declarations live inline in the consuming module, no separate module.
	mod.source = inlineHeaderImports(mod.source, path, provider);

	// Parse with recovery — always get partial AST, errors in state.errors
	const lr = lex(mod.source);
	if (!lr.ok) {
		mod.errors.push(createModuleError(`Lex: ${lr.error}`, 0, 0, ErrorSeverity.Error));
		finalizeModule(graph, mod, path);
		return false;
	}
	const parseState = createState(lr.value);
	const parseResult = callStateProgramParser(parseState);
	for (const parseErr of parseState.errors) {
		mod.errors.push(createModuleError(`Parse: ${parseErr}`, 0, 0, ErrorSeverity.Error));
	}
	// NOTE: keep state as Loading until imports are processed — cycle detection
	// in loadModule checks for Loading state to detect circular imports.

	// Walk AST for import declarations (works on partial ASTs)
	if (!parseResult.ok) {
		mod.errors.push(createModuleError(`Parse: ${parseResult.error}`, 0, 0, ErrorSeverity.Error));
		finalizeModule(graph, mod, path);
		return false;
	}
	const program = parseResult.value;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.ImportDecl) {
			processImportDecl(graph, mod, stmt, provider, config, useConfig);
		} else if (stmt.kind === NodeKind.ExportDecl) {
			// Re-export: export { ... } from "./module" wraps ImportDecl in ExportDecl
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.ImportDecl) {
				processImportDecl(graph, mod, ed.exportedDecl, provider, config, useConfig);
			}
		}
	}

	// Done loading — mark ready, add to topological order
	finalizeModule(graph, mod, path);
	return true;
}

// useConfig: 0 = bare (skip std, .ms only), 1 = full (use ResolverConfig)
export function loadModule(graph: ModuleGraph, path: string, provider: SourceProvider, config: ResolverConfig, useConfig: number): Result<boolean, string> {
	// Already in graph — check if still loading (circular import)
	if (hasModule(graph, path)) {
		const existing = findModule(graph, path);
		if (existing !== null) {
			if (existing.state === ModuleState.Loading) {
				// Implementation parity: record cycle info
				// Extract cycle path from importStack
				const cycle: string[] = [];
				let inCycle = false;
				for (const sp of graph.importStack) {
					if (sp === path) inCycle = true;
					if (inCycle) cycle.push(sp);
				}
				cycle.push(path); // close the cycle
				const fromPath = graph.importStack.length > 0
					? graph.importStack[graph.importStack.length - 1]
					: path;
				graph.circularDeps.push({ fromPath, toPath: path, cycle, importLine: 0, importNames: [] });
				// Not a hard error — two-phase checking handles circular deps gracefully
			}
		}
		return Result.ok(true);
	}

	// C header files: handled by inlineHeaderImports() in the consuming module.
	// No separate module needed — reference parity.
	if (isCHeaderPath(path)) {
		return Result.ok(true);
	}

	// Regular source module
	const loaded = loadSourceModule(graph, path, provider, config, useConfig);
	return Result.ok(loaded);
}

// ===== Import Processing =====

function processImportDecl(graph: ModuleGraph, mod: Module, node: Node, provider: SourceProvider, config: ResolverConfig, useConfig: number): void {
	const d = node.data as ImportDeclData;
	const specifier = d.importSource;

	if (useConfig === 0) {
		// Bare mode: skip std, resolve .ms only
		if (isStdImport(specifier)) return;

		const candidates = resolveImport(specifier, mod.path);
		let resolved = "";
		for (const candidate of candidates) {
			if (resolved === "") {
				const trySource = provideSource(provider, candidate);
				if (trySource.ok) {
					resolved = candidate;
				}
			}
		}

		if (resolved === "") {
			mod.errors.push(createModuleError(`Cannot resolve import '${specifier}'`, 0, 0, ErrorSeverity.Error));
			return;
		}

		const entry = createImportEntry(d.importNames, d.importAliases, resolved, specifier);
		mod.imports.push(entry);
		const preCircCount = graph.circularDeps.length;
		const _loadResult = loadModule(graph, resolved, provider, config, 0);
		// Enrich circular dep with import site info if a new cycle was just detected
		if (graph.circularDeps.length > preCircCount) {
			const lastDep = graph.circularDeps[graph.circularDeps.length - 1];
			lastDep.importLine = node.location !== null ? node.location.line : 0;
			lastDep.importNames = d.importNames;
		}
	} else {
		// Config-aware mode: resolve all imports including std/
		const candidates = resolveImportWithConfig(specifier, mod.path, config);

		let resolved = "";
		for (const candidate of candidates) {
			if (resolved === "") {
				const trySource = provideSource(provider, candidate);
				if (trySource.ok) {
					resolved = candidate;
				}
			}
		}

		if (resolved === "") {
			// std/ with empty stdPath: silently skip (handled externally)
			if (isStdImport(specifier) && config.stdPath.length === 0) return;
			mod.errors.push(createModuleError(`Cannot resolve import '${specifier}'`, 0, 0, ErrorSeverity.Error));
			return;
		}

		const entry = createImportEntry(d.importNames, d.importAliases, resolved, specifier);
		mod.imports.push(entry);
		const preCircCount2 = graph.circularDeps.length;
		const _loadResult = loadModule(graph, resolved, provider, config, 1);
		if (graph.circularDeps.length > preCircCount2) {
			const lastDep2 = graph.circularDeps[graph.circularDeps.length - 1];
			lastDep2.importLine = node.location !== null ? node.location.line : 0;
			lastDep2.importNames = d.importNames;
		}
	}
}

// ===== Convenience: Load from entry point =====

// Config-aware graph loading
export function loadModuleGraphWithConfig(entryPath: string, provider: SourceProvider, config: ResolverConfig): ModuleGraph {
	const graph = createModuleGraph();
	const _r = loadModule(graph, entryPath, provider, config, 1);
	return graph;
}

// Bare mode (no config) — skips std/, resolves .ms only
export function loadModuleGraph(entryPath: string, provider: SourceProvider): ModuleGraph {
	const graph = createModuleGraph();
	// Dummy config — not used in bare mode (useConfig=0)
	const dummyExts: string[] = [];
	const dummyCfg: ResolverConfig = { backend: 0, stdPath: "", searchPaths: [], extensions: dummyExts, aliasKeys: [], aliasValues: [] };
	const _r = loadModule(graph, entryPath, provider, dummyCfg, 0);
	return graph;
}

// ===== Tests =====

function makeEntry(path: string, source: string): MapEntry {
	return { entryPath: path, entrySource: source };
}

test "single file graph" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = 1;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length === 1;
	assert graph.loadOrder.length === 1;
	assert graph.loadOrder[0] === "/src/a.ms";
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.state === ModuleState.Ready;
	assert mod.source === "const x = 1;";
}

test "A imports B chain" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { foo } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "export function foo() { return 1; }"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length === 2;
	// Topological: B before A (dependency loaded first)
	assert graph.loadOrder[0] === "/src/b.ms";
	assert graph.loadOrder[1] === "/src/a.ms";
	// A has import entry pointing to B
	const modA = findModule(graph, "/src/a.ms");
	assert modA !== null;
	assert modA.imports.length === 1;
	assert modA.imports[0].sourcePath === "/src/b.ms";
}

test "circular import handled" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "import { a } from \"./a\";"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	// Both modules loaded (circular doesn't crash)
	assert graph.modules.length === 2;
	// Both end up in Ready state
	const modA = findModule(graph, "/src/a.ms");
	const modB = findModule(graph, "/src/b.ms");
	assert modA !== null;
	assert modB !== null;
	assert modA.state === ModuleState.Ready;
	assert modB.state === ModuleState.Ready;
}

test "diamond dependency" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; import { c } from \"./c\";"));
	entries.push(makeEntry("/src/b.ms", "import { d } from \"./d\"; export const b = 1;"));
	entries.push(makeEntry("/src/c.ms", "import { d } from \"./d\"; export const c = 2;"));
	entries.push(makeEntry("/src/d.ms", "export const d = 3;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length === 4;
	// D should be loaded once (not duplicated)
	assert graph.loadOrder[0] === "/src/d.ms";
	assert graph.errors.length === 0;
}

test "missing module error" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { x } from \"./missing\";"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.errors.length > 0;
}

test "std import skipped" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { test } from \"std/testing\"; const x = 1;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length === 1;
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.imports.length === 0;
}

test "no duplicate loading" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { x } from \"./b\"; import { y } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "export const x = 1; export const y = 2;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length === 2;
}

test "C header import inlines declarations" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/app.ms", "import { foo } from \"./lib.h\";"));
	entries.push(makeEntry("/src/lib.h", "void foo(int x);"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/app.ms", provider);
	// .h imports are inlined — no separate module created (reference parity)
	assert graph.modules.length === 1;
	assert graph.errors.length === 0;
	const hAppMod = findModule(graph, "/src/app.ms");
	assert hAppMod !== null;
	// The consuming module's source should contain the inlined extern declaration
	assert hAppMod.source.indexOf("extern") >= 0;
	const appMod = findModule(graph, "/src/app.ms");
	assert appMod !== null;
	assert appMod.errors.length === 0;
}

test "translateCHeader extracts struct after static inline functions" {
	const header = '#ifndef GUARD\n#define GUARD\n#include <stdio.h>\n\nstatic inline msString getFoo(void) {\n\treturn msStringFromCStr("foo");\n}\n\ntypedef struct {\n\tmsString name;\n\tint32_t age;\n} Person;\n\nstatic inline int32_t getAge(void) {\n\treturn 42;\n}\n\n#endif';
	const ms = translateCHeader(header, []);
	assert ms.indexOf("Person") >= 0;
	assert ms.indexOf("name: string") >= 0;
	assert ms.indexOf("age: int32") >= 0;
}

test "translateCHeader with empty filter extracts all" {
	const header = 'typedef struct {\n\tmsString model;\n\tint32_t speed;\n} CpuInfo;\n\nstatic inline msString getName(void) {\n\treturn msStringFromCStr("cpu");\n}';
	const ms = translateCHeader(header, []);
	assert ms.indexOf("CpuInfo") >= 0;
	assert ms.indexOf("model: string") >= 0;
	assert ms.indexOf("getName") >= 0;
}

test "parse error recorded" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = ;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.errors.length > 0;
	assert mod.state === ModuleState.Ready;
}

test "loadOrder is topological" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/main.ms", "import { a } from \"./a\";"));
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; export const a = 1;"));
	entries.push(makeEntry("/src/b.ms", "export const b = 2;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/main.ms", provider);
	assert graph.loadOrder[0] === "/src/b.ms";
	assert graph.loadOrder[1] === "/src/a.ms";
	assert graph.loadOrder[2] === "/src/main.ms";
}

test "module source stored" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = 42;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.source === "const x = 42;";
}
