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
	Module, ModuleGraph, ModuleState, createModuleGraph, createModule, createImportEntry,
	findModule, hasModule, addModule, pushImportStack, popImportStack, createModuleError, ModuleError, ErrorSeverity,
} from "./graph";
import { resolveImport, resolveImportWithConfig, isStdImport, ResolverConfig } from "./resolver";
import { lex } from "../lexer/lexer";
import { createState } from "../parser/context";
import { callStateProgramParser } from "../parser/statements/callbacks";
import "../parser/statements/core";
import { Node, NodeKind, ProgramData, ImportDeclData, ExportDeclData } from "../ast/node";
import { readFile, writeFile, ensureDir } from "std/fs";
import { translateCHeader } from "./cimport/emit";
import { Diagnostic, DiagSeverity } from "./cparse/error";
import { resolveRuntimeDir } from "../utils/path";
import { isAbsolute, dirname, join, normalize } from "std/fs/path";
import { cwd, env } from "std/process";
import { djb2, fingerprint, hashToHex } from "std/hash";
// (utils/string imports removed — using native .slice)

// ===== Source Provider =====

export interface MapEntry {
	entryPath: string;
	entrySource: string;
}

// Custom read function for Trans-Am integration. When set, bypasses entries/useFileSystem
// and uses the callback (which can record deps in the caller's query frame).
type TaReadFn = (path: string) => string;

export class SourceProvider {
	entries: MapEntry[];
	useFileSystem: boolean;
	taReadFn: TaReadFn;  // null for map/filesystem providers; non-null for Trans-Am-backed
	readLog: string[];   // null normally; set per-call by the header-inline cache wrapper to record every probe as "<path>\t<hash>" / "<path>\t-"
}

export function createMapProvider(entries: MapEntry[]): SourceProvider {
	return { entries, useFileSystem: false, taReadFn: null as unknown as TaReadFn, readLog: null as unknown as string[] };
}

export function createFileSystemProvider(): SourceProvider {
	return { entries: [], useFileSystem: true, taReadFn: null as unknown as TaReadFn, readLog: null as unknown as string[] };
}

// Trans-Am-backed provider. The callback MUST load the file into Trans-Am, record a
// FileText dependency on the current query frame, and return the raw source string.
// Constructed by transam/index.ms:createTaSourceProvider.
export function createTaReadProvider(readFn: TaReadFn): SourceProvider {
	return { entries: [], useFileSystem: false, taReadFn: readFn };
}

export function provideSource(provider: SourceProvider, path: string): Result<string, string> {
	if (provider.taReadFn != null) {
		const content = provider.taReadFn(path);
		if (content.length > 0) return Result.ok(content);
		return Result.err(`File not found: ${path}`);
	}
	for (const e of provider.entries) {
		if (e.entryPath == path) {
			if (provider.readLog != null) provider.readLog.push(`${path}\t${headerDepHash(e.entrySource)}`);
			return Result.ok(e.entrySource);
		}
	}
	if (provider.useFileSystem) {
		const content = try readFile(path) catch "";
		if (content.length > 0) {
			if (provider.readLog != null) provider.readLog.push(`${path}\t${headerDepHash(content)}`);
			const cached: MapEntry = { entryPath: path, entrySource: content };
			provider.entries.push(cached);
			return Result.ok(content);
		}
	}
	if (provider.readLog != null) provider.readLog.push(`${path}\t-`);
	return Result.err(`File not found: ${path}`);
}

// ===== C Header Detection =====

// Inline .h imports: scan source for `import { ... } from "*.h"` lines,
// and inject `@include` + extern declarations generated from the C header
// immediately AFTER the import statement. The original import statement is
// preserved so Phase B unused-import detection (which walks ImportDecl nodes)
// sees .h imports uniformly with .cms/.ms imports.
//
// collectImport treats .h sources as a special case: it skips ExportRegistry
// lookup and symbol creation because the inlined extern decls below define
// the symbols locally in the current module's scope.
// Build-perf §1.2: how much of the loader half is C-header translation
// (chibicc) vs plain read. Accumulated under graphLoadTiming; read by
// compile.ms's graphLoad print.
let _inlineMs: float64 = 0;
let _inlineN: int32 = 0;
let _inlineHits: int32 = 0;
export interface InlineHeaderTimings {
	ms: float64;
	n: int32;
	hits: int32;
}
export function takeInlineHeaderTimings(): InlineHeaderTimings {
	const r: InlineHeaderTimings = { ms: _inlineMs, n: _inlineN, hits: _inlineHits };
	_inlineMs = 0;
	_inlineN = 0;
	_inlineHits = 0;
	return r;
}

// ===== Header-Inline Disk Cache (build-perf Phase A0) =====
//
// inlineHeaderImports is a pure transform (module source + headers → source)
// and the compiler runs it twice per module per build (graph load + checker
// prelude load); the chibicc translation inside dominated the loader half.
// Cache mechanics live in compiler/cache.ms (Layer 5) — loader.ms cannot
// import that module (checker/context → module/graph would make the module
// layer depend on the checker), so the implementations are injected at
// compile.ms module load, the same cycle-breaker pattern as
// parser/statements/callbacks.ms.

type HeaderCacheKeyFn = (source: string, modulePath: string, compact: boolean) => string;
type HeaderCacheLookupFn = (key: string) => string;
type HeaderCacheStoreFn = (key: string, deps: string[], output: string) => void;

let _hcKeyFn: HeaderCacheKeyFn = null as unknown as HeaderCacheKeyFn;
let _hcLookupFn: HeaderCacheLookupFn = null as unknown as HeaderCacheLookupFn;
let _hcStoreFn: HeaderCacheStoreFn = null as unknown as HeaderCacheStoreFn;

export function registerHeaderCache(keyFn: HeaderCacheKeyFn, lookupFn: HeaderCacheLookupFn, storeFn: HeaderCacheStoreFn): void {
	_hcKeyFn = keyFn;
	_hcLookupFn = lookupFn;
	_hcStoreFn = storeFn;
}

// Same dual-hash as compiler/cache.ms hashContent — dep lines are keyed by it.
function headerDepHash(s: string): string {
	return `${hashToHex(djb2(s))}_${hashToHex(fingerprint(s))}`;
}

// Returns the cache key when this call should engage the disk cache, "" when
// not: cache unregistered, MSC_NO_HEADER_CACHE=1, non-filesystem provider
// (Trans-Am, pure map providers whose entries may not mirror disk), or a
// source that cannot contain a .h import at all.
function headerCacheEngage(source: string, modulePath: string, provider: SourceProvider, compactReplacement: boolean): string {
	if (_hcLookupFn == null) return "";
	if (provider.taReadFn != null || !provider.useFileSystem) return "";
	if (env.get("MSC_NO_HEADER_CACHE") != "") return "";
	if (source.indexOf(".h") < 0) return "";
	return _hcKeyFn(source, modulePath, compactReplacement);
}

export function inlineHeaderImports(source: string, modulePath: string, provider: SourceProvider, compactReplacement: boolean = false, outErrors: ModuleError[] = null as unknown as ModuleError[]): string {
	const _ih0 = performance.now();
	_inlineN = _inlineN + 1;
	const key = headerCacheEngage(source, modulePath, provider, compactReplacement);
	if (key != "") {
		const hit = _hcLookupFn(key);
		if (hit != "") {
			_inlineHits = _inlineHits + 1;
			_inlineMs = _inlineMs + (performance.now() - _ih0);
			return hit;
		}
	}
	const errLen0 = outErrors != null ? outErrors.length : 0;
	const prevLog = provider.readLog;
	const probeLog: string[] = [];
	const cparseReads: string[] = [];
	if (key != "") provider.readLog = probeLog;
	let deps: string[] = null as unknown as string[];
	let output = "";
	try {
		output = inlineHeaderImportsInner(source, modulePath, provider, compactReplacement, outErrors, key != "" ? cparseReads : (null as unknown as string[]));
	} finally {
		if (key != "") {
			const seen = new HashSet<string>();
			deps = [];
			for (const d of probeLog) {
				if (!seen.has(d)) { seen.add(d); deps.push(d); }
			}
			for (const d of cparseReads) {
				if (!seen.has(d)) { seen.add(d); deps.push(d); }
			}
			provider.readLog = prevLog;
		}
	}
	// Store only clean runs: a run that surfaced diagnostics must recompute
	// next time so the diagnostics re-surface. Output equal to source means
	// nothing was inlined — recomputing that is as cheap as a hit.
	if (key != "" && deps != null && output != source && (outErrors == null || outErrors.length == errLen0)) {
		_hcStoreFn(key, deps, output);
	}
	_inlineMs = _inlineMs + (performance.now() - _ih0);
	return output;
}

function inlineHeaderImportsInner(source: string, modulePath: string, provider: SourceProvider, compactReplacement: boolean, outErrors: ModuleError[], cparseReads: string[]): string {
	let result = source;
	let searchPos = 0;
	let insertedLines = 0;
	const emittedHeaderDecls = new HashSet<string>();
	while (searchPos < result.length) {
		// Find next import or re-export statement referencing a .h file
		let importIdx = result.indexOf("import ", searchPos);
		let exportIdx = result.indexOf("export {", searchPos);
		let isReexport = false;

		// Pick whichever comes first
		if (importIdx < 0 && exportIdx < 0) break;
		if (importIdx < 0) { importIdx = exportIdx; isReexport = true; }
		else if (exportIdx >= 0 && exportIdx < importIdx) { importIdx = exportIdx; isReexport = true; }

		// Skip matches inside // comments — find start of line, check for //
		let lineStart = result.lastIndexOf("\n", importIdx);
		if (lineStart < 0) lineStart = 0;
		const linePrefix = result.slice(lineStart, importIdx);
		if (linePrefix.indexOf("//") >= 0) {
			searchPos = importIdx + 7;
			continue;
		}

		// Find the full statement — terminated by ;
		const stmtEnd = result.indexOf(";", importIdx);
		if (stmtEnd < 0) { searchPos = importIdx + 7; continue; }
		const stmt = result.slice(importIdx, stmtEnd + 1);

		// Must have "from" clause with a .h specifier
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

		// Extract brace positions (shared by guard check and name extraction)
		const braceOpen = stmt.indexOf("{");
		const braceClose = stmt.indexOf("}");

		// For re-exports, must have { ... } braces (export { X as Y } from "*.h")
		if (isReexport && braceOpen < 0) { searchPos = importIdx + 7; continue; }

		// Resolve the .h file path relative to the consuming module
		let headerPath = specifier;
		if (specifier.startsWith("./") || specifier.startsWith("../")) {
			const moduleDir = dirname(modulePath);
			headerPath = moduleDir + "/" + specifier.slice(specifier.startsWith("./") ? 2 : 0, specifier.length);
		} else if (!isAbsolute(specifier)) {
			// Bare specifier ("lib/x.h"): module-relative first so the build does
			// not depend on the invocation CWD; std's bare paths (resolved via the
			// CWD/compiler-root chain below) miss here and keep their behavior.
			const moduleDir = dirname(modulePath);
			const moduleRel = moduleDir + "/" + specifier;
			if (provideSource(provider, moduleRel).ok) headerPath = moduleRel;
		}

		// Read the .h file. Try as-is first (works when CWD is project root). If that
		// fails for a bare relative path, try resolving against the compiler root —
		// this lets installed std (~/.metascript/std/...) work from any CWD without
		// rewriting `headerPath` (which downstream code uses to derive companion .c
		// paths and @include directives — must stay consistent).
		let headerSource = provideSource(provider, headerPath);
		if (!headerSource.ok && !isAbsolute(headerPath)) {
			const root = resolveRuntimeDir();
			if (root != "") headerSource = provideSource(provider, `${root}/${headerPath}`);
		}
		if (!headerSource.ok) {
			if (outErrors != null) {
				const missLine = countLinesBefore(result, importIdx) - insertedLines;
				outErrors.push(createModuleError(`cannot read C header '${specifier}' (resolved '${headerPath}')`, missLine, 1, ErrorSeverity.Error));
			}
			searchPos = importIdx + 7;
			continue;
		}

		// Parse specifier list once — used for both name filtering and re-export generation
		const specs = parseSpecItems(stmt, braceOpen, braceClose);
		const importedNames: string[] = [];
		for (const spec of specs) {
			importedNames.push(spec.origName);
		}

		// Generate extern declarations from C header
		// Include paths: builtin C headers (stdint.h etc.) + header's own directory
		// + its parent so `#include <libname/foo.h>` inside the lib resolves.
		const headerDir = dirname(headerPath);
		const headerParentDir = dirname(headerDir);
		const compilerRoot = resolveRuntimeDir();
		const builtinInclude = compilerRoot != "" ? compilerRoot + "/src/module/cparse/include" : "src/module/cparse/include";
		const includePaths = compilerRoot != ""
			? [builtinInclude, compilerRoot, headerDir, headerParentDir]
			: [builtinInclude, headerDir, headerParentDir];
		const headerDiags: Diagnostic[] = [];
		let translated = translateCHeader(headerSource.value, importedNames, false, headerPath, includePaths, headerDiags, emittedHeaderDecls, cparseReads);
		if (outErrors != null && headerDiags.length > 0) {
			const importLine = countLinesBefore(result, importIdx) - insertedLines;
			for (const hd of headerDiags) {
				const sev = hd.severity == DiagSeverity.Error ? ErrorSeverity.Error : ErrorSeverity.Warning;
				outErrors.push(createModuleError(`C header ${hd.file}:${hd.line}:${hd.col}: ${hd.message}`, importLine, 1, sev));
			}
		}

		// Auto-compile companion .c file if it exists (e.g., native.h → native.c).
		// Apply the same compiler-root fallback as the .h lookup above — when building
		// from a directory outside the compiler tree (e.g., an example project), the
		// bare relative path won't resolve against CWD; retrying under the compiler
		// root picks up `std` and `runtime` sources bundled with the install.
		const companionC = headerPath.slice(0, headerPath.length - 2) + ".c";
		let hasCompanionC = provideSource(provider, companionC).ok;
		if (!hasCompanionC && !isAbsolute(companionC)) {
			const root = resolveRuntimeDir();
			if (root != "") hasCompanionC = provideSource(provider, `${root}/${companionC}`).ok;
		}
		let compileDirective = "";
		if (hasCompanionC) compileDirective = `@compile("${companionC}");\n`;

		let replacement = "";
		if (isReexport) {
			replacement = buildReexportReplacement(translated, specs, headerPath, compileDirective);
		} else {
			replacement = `@include("${headerPath}");\n${compileDirective}${translated}`;
		}

		// Line-preserving mode: compact the replacement to one line AND keep the original
		// trailing newline so subsequent line numbers stay aligned with the user's source.
		// All decls are terminated by `;` or `}`, so collapsing newlines to spaces is safe.
		// Without this, multi-line replacements shift downstream line numbers, breaking
		// LSP hover/goto positions.
		if (compactReplacement) {
			replacement = replacement.split("\n").join(" ");
		}

		// Insert the inlined declarations immediately AFTER the import statement.
		// The original `import { ... } from "*.h";` is PRESERVED so:
		//   - Phase B unused-import detection (checker/checkPass.ms:reportUnusedImports)
		//     walks its ImportDecl node uniformly with .cms/.ms imports
		//   - LSP hover/goto positions on the import clause are natural (real tokens)
		//   - collectImport short-circuits on .h sources; the extern decls inlined
		//     below actually define the symbols in the current module's scope.
		// In compact mode the replacement is collapsed to one line so downstream
		// line numbers stay aligned with the user's original source.
		const insertPos = stmtEnd + 1;  // just past the ';' of the import
		const sep = compactReplacement ? " " : "\n";
		result = result.slice(0, insertPos) + sep + replacement + result.slice(insertPos, result.length);
		searchPos = insertPos + sep.length + replacement.length;
		if (!compactReplacement) {
			insertedLines = insertedLines + countLinesBefore(replacement, replacement.length);
		}
	}
	return result;
}

// Line number (1-based) of the character at endPos, counting inserted text —
// callers subtract their own insertion count to recover original-source lines.
function countLinesBefore(text: string, endPos: int32): int32 {
	let n = 1;
	for (let i = 0; i < endPos; i += 1) {
		if (text.charCodeAt(i) == "\n".code) n = n + 1;
	}
	return n;
}

// Parse "{ A, B as C }" into original names and alias pairs.
interface SpecItem { origName: string; aliasName: string; }
function parseSpecItems(stmt: string, braceOpen: int32, braceClose: int32): SpecItem[] {
	const items: SpecItem[] = [];
	if (braceOpen < 0 || braceClose <= braceOpen) return items;
	const parts = stmt.slice(braceOpen + 1, braceClose).split(",");
	for (const part of parts) {
		const trimmed = part.trim();
		if (trimmed.length == 0) continue;
		const asIdx = trimmed.indexOf(" as ");
		if (asIdx > 0) {
			items.push({ origName: trimmed.slice(0, asIdx).trim(), aliasName: trimmed.slice(asIdx + 4, trimmed.length).trim() });
		} else {
			items.push({ origName: trimmed, aliasName: "" });
		}
	}
	return items;
}

// Prefix `export ` onto every occurrence of `marker` that ends at an
// identifier boundary. `extern function YGNodeNew` must NOT match inside
// `extern function YGNodeNewWithConfig` — a naive split/join exportizes the
// longer name's line too, and the longer name's own pass then produces
// `export export`. Returns "" when no boundary-valid occurrence exists.
function exportizeAtIdentBoundary(text: string, marker: string): string {
	let out = "";
	let pos = 0;
	let hit = false;
	while (true) {
		const idx = text.indexOf(marker, pos);
		if (idx < 0) {
			out = out + text.slice(pos, text.length);
			break;
		}
		const after = idx + marker.length;
		const ch = after < text.length ? text.charCodeAt(after) : 0;
		const isIdentChar = (ch >= "A".code && ch <= "Z".code) || (ch >= "a".code && ch <= "z".code)
			|| (ch >= "0".code && ch <= "9".code) || ch == "_".code;
		out = out + text.slice(pos, idx);
		if (isIdentChar) {
			out = out + marker;
		} else {
			out = out + "export " + marker;
			hit = true;
		}
		pos = after;
	}
	if (!hit) return "";
	return out;
}

// Build re-export replacement: inline externs + aliased export declarations.
function buildReexportReplacement(translated: string, specs: SpecItem[], headerPath: string, compileDirective: string): string {
	let reexportDecls = "";
	let exportTranslated = translated;

	for (const spec of specs) {
		if (spec.aliasName != "") {
			// Aliased: find the translated extern and re-emit with alias + from clause
			const declMarker = ` ${spec.origName}(`;
			const structMarker = ` ${spec.origName} {`;
			const typeMarker = ` ${spec.origName} =`;
			if (translated.indexOf(declMarker) >= 0) {
				const dIdx = translated.indexOf(declMarker);
				const lineStart = translated.lastIndexOf("\n", dIdx);
				const lineEnd = translated.indexOf("\n", dIdx);
				const declLine = translated.slice(lineStart >= 0 ? lineStart + 1 : 0, lineEnd >= 0 ? lineEnd : translated.length);
				let aliasDecl = declLine.split(`extern function ${spec.origName}`).join(`export extern function ${spec.aliasName}`);
				if (aliasDecl.endsWith(";")) {
					aliasDecl = aliasDecl.slice(0, aliasDecl.length - 1) + ` from "${spec.origName}";`;
				}
				reexportDecls = reexportDecls + aliasDecl + "\n";
			} else if (translated.indexOf(structMarker) >= 0 || translated.indexOf(typeMarker) >= 0) {
				reexportDecls = reexportDecls + `export type ${spec.aliasName} = ${spec.origName};\n`;
			}
		} else {
			// Non-aliased: re-add export prefix to matching extern
			const kinds = ["function", "interface", "struct", "enum", "type"];
			for (const k of kinds) {
				const marker = `extern ${k} ${spec.origName}`;
				const replaced = exportizeAtIdentBoundary(exportTranslated, marker);
				if (replaced != "") {
					exportTranslated = replaced;
					break;
				}
			}
		}
	}

	return `@include("${headerPath}");\n${compileDirective}${exportTranslated}${reexportDecls}`;
}

export function isCHeaderPath(path: string): boolean {
	if (path.length < 3) return false;
	return path.slice(path.length - 2, path.length) == ".h";
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
function loadSourceModule(graph: ModuleGraph, path: string, provider: SourceProvider, config: ResolverConfig, useConfig: int32): boolean {
	const mod = createModule(path);
	mod.state = ModuleState.Loading;
	addModule(graph, mod);
	pushImportStack(graph, path);

	const sourceResult = provideSource(provider, path);
	if (!sourceResult.ok) {
		mod.errors.push(createModuleError(sourceResult.error, 0, 0, ErrorSeverity.Error));
		finalizeModule(graph, mod, path);
		return false;
	}
	mod.source = sourceResult.value;

	// Inline .h imports: replace `import { ... } from "*.h"` with extern declarations.
	// reference parity: importc declarations live inline in the consuming module, no separate module.
	const headerErrors: ModuleError[] = [];
	mod.source = inlineHeaderImports(mod.source, path, provider, false, headerErrors);
	for (const he of headerErrors) mod.errors.push(he);

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
		if (stmt.kind == NodeKind.ImportDecl) {
			const d = stmt.data as ImportDeclData;
			// .h imports are fully handled by inlineHeaderImports above (which inlined
			// extern decls alongside this ImportDecl). The ImportDecl is kept purely for
			// checker unused-import detection; don't try to resolve it as a module.
			if (isCHeaderPath(d.importSource)) continue;
			processImportDecl(graph, mod, stmt, provider, config, useConfig);
		} else if (stmt.kind == NodeKind.ExportDecl) {
			// Re-export: export { ... } from "./module" wraps ImportDecl in ExportDecl
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl != null && ed.exportedDecl.kind == NodeKind.ImportDecl) {
				const id = ed.exportedDecl.data as ImportDeclData;
				if (isCHeaderPath(id.importSource)) continue;
				processImportDecl(graph, mod, ed.exportedDecl, provider, config, useConfig);
			}
		}
	}

	// Done loading — mark ready, add to topological order
	finalizeModule(graph, mod, path);
	return true;
}

// Canonicalize a module path: relative paths get joined with cwd so the
// graph keys every file by its absolute path. Without this, a file resolved
// via different code paths (e.g. entry passed as `src/index.ms` vs prelude
// loaded via absolute stdPath) gets two distinct graph entries → two .o
// files emitted with overlapping global symbols → linker duplicate-symbol
// error. Map-provider test paths like `/src/a.ms` already absolute → pass
// through unchanged.
export function canonicalModulePath(path: string): string {
	// Normalize regardless of absolute/relative: a module's identity must collapse
	// `..`/`.` segments so the same file reached via different import spellings
	// (e.g. `crypto/index` vs `crypto/tls/../index`) maps to ONE module — otherwise
	// it loads twice under two identities, emitting duplicate symbols whose mangled
	// names diverge by path → undefined-symbol link errors.
	if (isAbsolute(path)) return normalize(path);
	return normalize(join(cwd(), path));
}

function canonicalizeStdModule(path: string, stdPath: string, provider: SourceProvider): string {
	if (stdPath.length == 0) return path;
	let dir = dirname(path);
	let stepsUp = 0;
	while (dir.length > 1 && stepsUp < 6) {
		const marker = join(dir, "std/core/system/index.ms");
		if (provideSource(provider, marker).ok) {
			const prefix = join(dir, "std") + "/";
			if (path.length > prefix.length && path.slice(0, prefix.length) == prefix) {
				const subpath = path.slice(prefix.length, path.length);
				const candidate = join(stdPath, subpath);
				if (provideSource(provider, candidate).ok) return candidate;
			}
			return path;
		}
		const parent = dirname(dir);
		if (parent == dir) return path;
		dir = parent;
		stepsUp = stepsUp + 1;
	}
	return path;
}

// useConfig: 0 = bare (skip std, .ms only), 1 = full (use ResolverConfig)
export function loadModule(graph: ModuleGraph, path: string, provider: SourceProvider, config: ResolverConfig, useConfig: int32): Result<boolean, string> {
	path = canonicalModulePath(path);
	path = canonicalizeStdModule(path, config.stdPath, provider);
	// Already in graph — check if still loading (circular import)
	if (hasModule(graph, path)) {
		const existing = findModule(graph, path);
		if (existing != null) {
			if (existing.state == ModuleState.Loading) {
				// Implementation parity: record cycle info
				// Extract cycle path from importStack
				const cycle: string[] = [];
				let inCycle = false;
				for (const sp of graph.importStack) {
					if (sp == path) inCycle = true;
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

function processImportDecl(graph: ModuleGraph, mod: Module, node: Node, provider: SourceProvider, config: ResolverConfig, useConfig: int32): void {
	const d = node.data as ImportDeclData;
	const specifier = d.importSource;

	if (useConfig == 0) {
		// Bare mode: skip std, resolve .ms only
		if (isStdImport(specifier)) return;

		const candidates = resolveImport(specifier, mod.path);
		let resolved = "";
		for (const candidate of candidates) {
			if (resolved == "") {
				const trySource = provideSource(provider, candidate);
				if (trySource.ok) {
					resolved = candidate;
				}
			}
		}

		if (resolved == "") {
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
			lastDep.importLine = node.location != null ? node.location.line : 0;
			lastDep.importNames = d.importNames;
		}
	} else {
		// Config-aware mode: resolve all imports including std/
		const candidates = resolveImportWithConfig(specifier, mod.path, config);

		let resolved = "";
		for (const candidate of candidates) {
			if (resolved == "") {
				const trySource = provideSource(provider, candidate);
				if (trySource.ok) {
					resolved = candidate;
				}
			}
		}

		if (resolved == "") {
			// std/ with empty stdPath: silently skip (handled externally)
			if (isStdImport(specifier) && config.stdPath.length == 0) return;
			mod.errors.push(createModuleError(`Cannot resolve import '${specifier}'`, 0, 0, ErrorSeverity.Error));
			return;
		}

		const entry = createImportEntry(d.importNames, d.importAliases, resolved, specifier);
		mod.imports.push(entry);
		const preCircCount2 = graph.circularDeps.length;
		const _loadResult = loadModule(graph, resolved, provider, config, 1);
		if (graph.circularDeps.length > preCircCount2) {
			const lastDep2 = graph.circularDeps[graph.circularDeps.length - 1];
			lastDep2.importLine = node.location != null ? node.location.line : 0;
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
	assert graph.modules.length == 1;
	assert graph.loadOrder.length == 1;
	assert graph.loadOrder[0] == "/src/a.ms";
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.state == ModuleState.Ready;
	assert mod.source == "const x = 1;";
}

test "inlineHeaderImports surfaces missing-include diagnostics with .ms import line" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/tmp/msdiagtest/bad.h", "#include <nope/nada.h>\nint diagOk(void);\n"));
	const provider = createMapProvider(entries);
	const src = "// lead line\nimport { diagOk } from " + "\"./bad.h\";\n";
	const errs: ModuleError[] = [];
	const inlined = inlineHeaderImports(src, "/tmp/msdiagtest/main.ms", provider, false, errs);
	assert inlined.indexOf("extern function diagOk") >= 0;
	assert errs.length > 0;
	assert errs[0].message.indexOf("nada.h") >= 0;
	assert errs[0].message.indexOf("file not found") >= 0;
	assert errs[0].line == 2;
}

test "inlineHeaderImports surfaces unreadable .h as Error instead of silent skip" {
	const provider = createMapProvider([]);
	const src = "import { ghost } from " + "\"./missing.h\";\n";
	const errs: ModuleError[] = [];
	const inlined = inlineHeaderImports(src, "/tmp/msmissing/main.ms", provider, false, errs);
	assert inlined.indexOf("extern function ghost") < 0;
	assert errs.length == 1;
	assert errs[0].severity == ErrorSeverity.Error;
	assert errs[0].message.indexOf("missing.h") >= 0;
	assert errs[0].line == 1;
}

test "inlineHeaderImports resolves bare .h specifier module-relative (CWD-independent)" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/tmp/msbarespec/lib/api.h", "int bareOk(void);\n"));
	const provider = createMapProvider(entries);
	const src = "import { bareOk } from " + "\"lib/api.h\";\n";
	const inlined = inlineHeaderImports(src, "/tmp/msbarespec/main.ms", provider);
	assert inlined.indexOf("extern function bareOk") >= 0;
}

test "re-export from .h with prefix-colliding names does not double-export" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/tmp/msprefix/api.h", "int fooBar(void);\nint fooBarBaz(void);\n"));
	const provider = createMapProvider(entries);
	const src = "export { fooBar, fooBarBaz } from " + "\"./api.h\";\n";
	const inlined = inlineHeaderImports(src, "/tmp/msprefix/main.ms", provider);
	assert inlined.indexOf("export extern function fooBar(") >= 0;
	assert inlined.indexOf("export extern function fooBarBaz(") >= 0;
	assert inlined.indexOf("export export") < 0;
}

test "A imports B chain" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { foo } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "export function foo() { return 1; }"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length == 2;
	// Topological: B before A (dependency loaded first)
	assert graph.loadOrder[0] == "/src/b.ms";
	assert graph.loadOrder[1] == "/src/a.ms";
	// A has import entry pointing to B
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.imports.length == 1;
	assert modA.imports[0].sourcePath == "/src/b.ms";
}

test "circular import handled" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "import { a } from \"./a\";"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	// Both modules loaded (circular doesn't crash)
	assert graph.modules.length == 2;
	// Both end up in Ready state
	const modA = findModule(graph, "/src/a.ms");
	const modB = findModule(graph, "/src/b.ms");
	assert modA != null;
	assert modB != null;
	assert modA.state == ModuleState.Ready;
	assert modB.state == ModuleState.Ready;
}

test "diamond dependency" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; import { c } from \"./c\";"));
	entries.push(makeEntry("/src/b.ms", "import { d } from \"./d\"; export const b = 1;"));
	entries.push(makeEntry("/src/c.ms", "import { d } from \"./d\"; export const c = 2;"));
	entries.push(makeEntry("/src/d.ms", "export const d = 3;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length == 4;
	// D should be loaded once (not duplicated)
	assert graph.loadOrder[0] == "/src/d.ms";
	assert graph.errors.length == 0;
}

test "missing module error" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { x } from \"./missing\";"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.errors.length > 0;
}

test "std import skipped" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { test } from \"std/testing\"; const x = 1;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length == 1;
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.imports.length == 0;
}

test "no duplicate loading" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { x } from \"./b\"; import { y } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "export const x = 1; export const y = 2;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length == 2;
}

test "C header import inlines declarations" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/app.ms", "import { foo } from \"./lib.h\";"));
	entries.push(makeEntry("/src/lib.h", "void foo(int x);"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/app.ms", provider);
	// .h imports are inlined — no separate module created (reference parity)
	assert graph.modules.length == 1;
	assert graph.errors.length == 0;
	const hAppMod = findModule(graph, "/src/app.ms");
	assert hAppMod != null;
	// The consuming module's source should contain the inlined extern declaration
	assert hAppMod.source.indexOf("extern") >= 0;
	const appMod = findModule(graph, "/src/app.ms");
	assert appMod != null;
	assert appMod.errors.length == 0;
}

test "parse error recorded" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = ;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.errors.length > 0;
	assert mod.state == ModuleState.Ready;
}

test "loadOrder is topological" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/main.ms", "import { a } from \"./a\";"));
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; export const a = 1;"));
	entries.push(makeEntry("/src/b.ms", "export const b = 2;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/main.ms", provider);
	assert graph.loadOrder[0] == "/src/b.ms";
	assert graph.loadOrder[1] == "/src/a.ms";
	assert graph.loadOrder[2] == "/src/main.ms";
}

test "module source stored" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = 42;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.source == "const x = 42;";
}

// ===== Header-Inline Cache Wrapper Tests =====
//
// These exercise the WRAPPER (engagement gating, hit short-circuit, dep
// harvest, store conditions) against an injected fake cache; the disk
// mechanics (entry format, dep verification, marker GC) live in
// compiler/cache.ms Layer 5 tests. Restore the null registration after each
// test so later tests in the binary run cache-neutral.

function unregisterHeaderCacheForTest(): void {
	registerHeaderCache(null as unknown as HeaderCacheKeyFn, null as unknown as HeaderCacheLookupFn, null as unknown as HeaderCacheStoreFn);
}

test "header cache wrapper: miss stores deps+output, hit short-circuits" {
	ensureDir("/tmp/mshcw");
	writeFile("/tmp/mshcw/a.h", "extern int hcwA(void);\n");
	const src = "import { hcwA } from " + "\"./a.h\";\n";
	let storedKey = "";
	let storedDeps: string[] = [];
	let storedOut = "";
	registerHeaderCache(
		(_s: string, _m: string, _c: boolean) => "KHCW",
		(k: string) => { return k == "KHCW" && storedOut != "" ? storedOut : ""; },
		(k: string, d: string[], o: string) => { storedKey = k; storedDeps = d; storedOut = o; }
	);
	takeInlineHeaderTimings();
	const out1 = inlineHeaderImports(src, "/tmp/mshcw/main.ms", createFileSystemProvider());
	assert storedKey == "KHCW";
	assert storedOut == out1;
	assert out1.indexOf("extern function hcwA") >= 0;
	let sawHeader = false;
	for (const d of storedDeps) {
		if (d.indexOf("/tmp/mshcw/a.h\t", 0) == 0) sawHeader = true;
	}
	assert sawHeader;
	const out2 = inlineHeaderImports(src, "/tmp/mshcw/main.ms", createFileSystemProvider());
	assert out2 == out1;
	const t = takeInlineHeaderTimings();
	assert t.hits == 1;
	assert t.n == 2;
	unregisterHeaderCacheForTest();
}

test "header cache wrapper: diagnostics-producing runs are not stored" {
	const src = "import { nope } from " + "\"./missing.h\";\n";
	let storeCalls = 0;
	registerHeaderCache(
		(_s: string, _m: string, _c: boolean) => "KERR",
		(_k: string) => "",
		(_k: string, _d: string[], _o: string) => { storeCalls = storeCalls + 1; }
	);
	const errs: ModuleError[] = [];
	const out = inlineHeaderImports(src, "/tmp/mshcw/miss.ms", createFileSystemProvider(), false, errs);
	assert errs.length > 0;
	assert out.indexOf("extern function nope") < 0;
	assert storeCalls == 0;
	unregisterHeaderCacheForTest();
}

test "header cache wrapper: map providers bypass the cache" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/virt/b.h", "extern int vB(void);\n"));
	registerHeaderCache(
		(_s: string, _m: string, _c: boolean) => "KMAP",
		(_k: string) => "SHOULD-NEVER-SERVE",
		(_k: string, _d: string[], _o: string) => {}
	);
	const src = "import { vB } from " + "\"/virt/b.h\";\n";
	const out = inlineHeaderImports(src, "/virt/main.ms", createMapProvider(entries));
	assert out.indexOf("SHOULD-NEVER-SERVE") < 0;
	assert out.indexOf("extern function vB") >= 0;
	unregisterHeaderCacheForTest();
}
