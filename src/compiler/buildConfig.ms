// MetaScript Compiler CLI — build.ms config loader
// Uses AST parsing to extract config from build.ms (no Raiser VM needed).

import { platform } from "std/process";
import { exists, readFile, ensureDir, writeFile, removeAll } from "std/fs";
import { registerCoreParsers } from "../parser/statements/core";
import { parseSource } from "../parser/statements/validation";
import { resolveImportWithConfig, createDefaultConfig, Backend } from "../module/resolver";
import {
	Node, NodeKind, NodeFlag, ProgramData, VariableDeclData, ExportDeclData,
	ExprStmtData, IdentifierData,
	ObjectLiteralData, ArrayLiteralData, NumberLiteralData, StringLiteralData, BooleanLiteralData,
} from "../ast/node";

// --- Interfaces ---

export interface BuildSection {
	target: string;
	outDir: string;
	outFile: string;
	optimize: string;
	cacheDir: string;
	globalCacheDir: string;
	globalCache: boolean;
	trimpath: boolean;
	cacheError: string;
}

export function defaultBuildSection(): BuildSection {
	return {
		target: "c",
		outDir: "out",
		outFile: "",
		optimize: "debug",
		cacheDir: "",
		globalCacheDir: "",
		globalCache: true,
		trimpath: false,
		cacheError: "",
	};
}

export function validateCacheDirectory(value: string): Result<void, string> {
	if (value.length == 0) return Result.err("must be a non-empty string");
	for (let i: int32 = 0; i < value.length; i += 1) {
		const code = value.charCodeAt(i);
		if (code < 32 || code == 127 || code == 133 || code == 8232 || code == 8233) {
			return Result.err("must not contain NUL or control characters");
		}
	}
	return Result.ok(null);
}

// `defines: { name: value }` — the project's `-d:` switches, as Nim's project config files carry
// `define:` (read before the command line, which overrides them).
export interface DefinesSection {
	keys: string[];
	values: string[];
	refused: string[];
}

export interface ResolveSection {
	searchPaths: string[];
	extensions: string[];
	aliasKeys: string[];
	aliasValues: string[];
}

export interface FmtSection {
	printWidth: int32;
	tabWidth: int32;
	useTabs: int32;        // -1 = unset, 0 = false, 1 = true
	singleQuote: int32;    // -1 = unset, 0 = false, 1 = true
}

export function defaultFmtSection(): FmtSection {
	return { printWidth: -1, tabWidth: -1, useTabs: -1, singleQuote: -1 };
}

export interface LspSection {
	os: string;            // "" = host platform
	mm: string;            // "" = what the target implies, see targetMemoryMode
}

export function defaultLspSection(): LspSection {
	return { os: "", mm: "" };
}

export function targetMemoryMode(os: string, requested: string): string {
	if (os == "solana") return requested == "none" ? "none" : "manual";
	if (requested != "") return requested;
	return os == "bare" ? "manual" : "drc";
}

export interface CcTargetSection {
	entry: string;
	compiler: string;
	flags: string[];
	linkFlags: string[];
}

export interface CcSection {
	compiler: string;          // default C compiler binary
	flags: string[];           // default extra compile flags
	linkFlags: string[];       // default extra link flags
	targetKeys: string[];      // per-target keys (e.g. ["linux-x86_64", "linux-arm64"])
	targetValues: CcTargetSection[];  // per-target overrides (parallel to targetKeys)
}

export function defaultCcSection(): CcSection {
	const f: string[] = [];
	const lf: string[] = [];
	const tk: string[] = [];
	const tv: CcTargetSection[] = [];
	return { compiler: "", flags: f, linkFlags: lf, targetKeys: tk, targetValues: tv };
}

// Well-known cross-compiler binary for common os-cpu targets.
// Covers 90% of cross-compile use cases without explicit config.
function defaultCompilerForTarget(targetOs: string, cpuTarget: string): string {
	const key = `${targetOs}-${cpuTarget}`;
	if (key == "linux-amd64") return "x86_64-unknown-linux-gnu-gcc";
	if (key == "linux-arm64") return "aarch64-unknown-linux-gnu-gcc";
	if (key == "linux-386") return "i686-unknown-linux-gnu-gcc";
	if (key == "linux-riscv64") return "riscv64-unknown-linux-gnu-gcc";
	if (key == "linux-mips64") return "mips64-unknown-linux-gnu-gcc";
	if (key == "windows-amd64") return "x86_64-w64-mingw32-gcc";
	if (key == "windows-386") return "i686-w64-mingw32-gcc";
	if (key == "windows-arm64") return "aarch64-w64-mingw32-gcc";
	return "";
}

// Resolve CcSection for a specific os-cpu target.
// Priority: explicit per-target config > cc.compiler default > well-known default.
// Cross detected via `targetOs !== platform || cpuTarget !== ""`.
export function resolveCcForTarget(cc: CcSection, targetOs: string, cpuTarget: string): CcTargetSection {
	let entry = "";
	let compiler = cc.compiler;
	let flags = cc.flags;
	let linkFlags = cc.linkFlags;

	if (targetOs != platform || cpuTarget != "") {
		const key = `${targetOs}-${cpuTarget}`;
		let i = 0;
		while (i < cc.targetKeys.length) {
			if (cc.targetKeys[i] == key) {
				const t = cc.targetValues[i];
				if (t.entry != "") entry = t.entry;
				if (t.compiler != "") compiler = t.compiler;
				if (t.flags.length > 0) flags = t.flags;
				if (t.linkFlags.length > 0) linkFlags = t.linkFlags;
				break;
			}
			i += 1;
		}
		// Fallback to well-known cross-compiler if nothing configured
		if (compiler == "") {
			compiler = defaultCompilerForTarget(targetOs, cpuTarget);
		}
	}

	return { entry, compiler, flags, linkFlags };
}

export interface PackageSection {
	name: string;
	version: string;
	description: string;
	license: string;
	repository: string;
	homepage: string;
	keywords: string[];
	author: string;
	files: string[];        // publish include globs (empty = all)
	ignore: string[];       // publish exclude globs (applied after files)
	bin: DepsSection;       // command name → .ms entry, relative to the package root
	valid: boolean;         // false if no `package` block present
}

export function defaultPackageSection(): PackageSection {
	const kw: string[] = [];
	const files: string[] = [];
	const ignore: string[] = [];
	return { name: "", version: "", description: "", license: "", repository: "", homepage: "", keywords: kw, author: "", files, ignore, bin: defaultDepsSection(), valid: false };
}

export interface DepsSection {
	keys: string[];         // package names / aliases
	values: string[];       // version strings ("1.2.3" or "git+github.com/...")
}

export function defaultDepsSection(): DepsSection {
	const k: string[] = [];
	const v: string[] = [];
	return { keys: k, values: v };
}

export interface BuildConfig {
	entry: string;
	build: BuildSection;
	resolve: ResolveSection;
	fmt: FmtSection;
	lsp: LspSection;
	cc: CcSection;
	package: PackageSection;
	deps: DepsSection;
	devDeps: DepsSection;
	globalImports: string[];
	defines: DefinesSection;
	modulePassFrom: string[];
	modulePassMacro: string[];
	valid: boolean;
}

// --- Public API ---

export function defaultResolveSection(): ResolveSection {
	const sp: string[] = [];
	const ext: string[] = [];
	const ak: string[] = [];
	const av: string[] = [];
	return { searchPaths: sp, extensions: ext, aliasKeys: ak, aliasValues: av };
}

// Extract ResolveSection from an ObjectLiteral node.
// Parses: resolve: { alias: { "@key": "value", ... } }
function extractResolve(resolveNode: Node): ResolveSection {
	const rs = defaultResolveSection();
	if (resolveNode == null || resolveNode.kind != NodeKind.ObjectLiteral) return rs;
	const aliasNode = findObjField(resolveNode, "alias");
	if (aliasNode != null && aliasNode.kind == NodeKind.ObjectLiteral) {
		const od = aliasNode.data as ObjectLiteralData;
		for (let i = 0; i < od.keys.length; i = i + 1) {
			const key = od.keys[i];
			const val = i < od.properties.length ? nodeString(od.properties[i]) : "";
			if (key.length > 0 && val.length > 0) {
				rs.aliasKeys.push(key);
				rs.aliasValues.push(val);
			}
		}
	}
	return rs;
}

// --- AST-based config extraction ---

// Find a named field in an ObjectLiteral by key name. Returns null if not found.
function findObjField(node: Node, key: string): Node {
	if (node == null || node.kind != NodeKind.ObjectLiteral) return null as unknown as Node;
	const od = node.data as ObjectLiteralData;
	for (let i = 0; i < od.keys.length; i = i + 1) {
		if (od.keys[i] == key && i < od.properties.length) return od.properties[i];
	}
	return null as unknown as Node;
}

// Extract a string value from a node (StringLiteral only).
function nodeString(node: Node): string {
	if (node == null || node.kind != NodeKind.StringLiteral) return "";
	return (node.data as StringLiteralData).value;
}

// Extract a number value from a node (NumberLiteral only).
function nodeNumber(node: Node): number {
	if (node == null || node.kind != NodeKind.NumberLiteral) return -1;
	return (node.data as NumberLiteralData).value;
}

// Extract a string array from an ArrayLiteral node.
function nodeStringArray(node: Node): string[] {
	const result: string[] = [];
	if (node == null || node.kind != NodeKind.ArrayLiteral) return result;
	const ad = node.data as ArrayLiteralData;
	for (const elem of ad.elements) {
		const s = nodeString(elem);
		if (s.length > 0) result.push(s);
	}
	return result;
}

// Extract a boolean value from a node. Returns -1 if not bool, 0 for false, 1 for true.
function nodeBool(node: Node): int32 {
	if (node == null || node.kind != NodeKind.BooleanLiteral) return -1;
	return (node.data as BooleanLiteralData).boolValue ? 1 : 0;
}

function findConfigObject(program: Node): Node | null {
	if (program == null || program.kind != NodeKind.Program) return null;
	const pd = program.data as ProgramData;
	let defaultExpr: Node | null = null;
	let exportIndex: int32 = -1;
	for (let i: int32 = 0; i < pd.programStmts.length; i += 1) {
		const stmt = pd.programStmts[i];
		if (stmt.kind != NodeKind.ExportDecl || !stmt.flags.has(NodeFlag.ExportDefault)) continue;
		const decl = (stmt.data as ExportDeclData).exportedDecl;
		if (defaultExpr != null || decl.kind != NodeKind.ExprStmt) return null;
		defaultExpr = (decl.data as ExprStmtData).expr;
		exportIndex = i;
	}
	let exportName = "";
	if (defaultExpr != null) {
		if (defaultExpr.kind == NodeKind.ObjectLiteral) return defaultExpr;
		if (defaultExpr.kind != NodeKind.Identifier) return null;
		exportName = (defaultExpr.data as IdentifierData).name;
	}
	let configObj: Node | null = null;
	for (let i: int32 = 0; i < pd.programStmts.length; i += 1) {
		let stmt = pd.programStmts[i];
		if (stmt.kind == NodeKind.ExportDecl) stmt = (stmt.data as ExportDeclData).exportedDecl;
		if (stmt.kind != NodeKind.VariableDecl) continue;
		const vd = stmt.data as VariableDeclData;
		if (exportName != "" && vd.declName != exportName) continue;
		if (exportName != "" && i > exportIndex) return null;
		if (vd.initializer == null || vd.initializer.kind != NodeKind.ObjectLiteral) {
			if (exportName != "") return null;
			continue;
		}
		if (configObj != null) return null;
		configObj = vd.initializer;
	}
	return configObj;
}

// Extract FmtSection from an ObjectLiteral node.
function extractFmt(fmtNode: Node): FmtSection {
	const fmt = defaultFmtSection();
	if (fmtNode == null || fmtNode.kind != NodeKind.ObjectLiteral) return fmt;
	const pw = findObjField(fmtNode, "printWidth");
	if (pw != null) { const v = nodeNumber(pw); if (v >= 0) { fmt.printWidth = v as int32; } }
	const tw = findObjField(fmtNode, "tabWidth");
	if (tw != null) { const v = nodeNumber(tw); if (v >= 0) { fmt.tabWidth = v as int32; } }
	const ut = findObjField(fmtNode, "useTabs");
	if (ut != null) { fmt.useTabs = nodeBool(ut); }
	const sq = findObjField(fmtNode, "singleQuote");
	if (sq != null) { fmt.singleQuote = nodeBool(sq); }
	return fmt;
}

// Extract LspSection from an ObjectLiteral node.
function extractLsp(lspNode: Node): LspSection {
	const lsp = defaultLspSection();
	if (lspNode == null || lspNode.kind != NodeKind.ObjectLiteral) return lsp;
	const os = nodeString(findObjField(lspNode, "os"));
	if (os.length > 0) lsp.os = os;
	const mm = nodeString(findObjField(lspNode, "mm"));
	if (mm.length > 0) lsp.mm = mm;
	return lsp;
}

// Extract a CcTargetSection from an ObjectLiteral node.
function extractCcTarget(node: Node): CcTargetSection {
	const ef: string[] = [];
	const elf: string[] = [];
	const t: CcTargetSection = { entry: "", compiler: "", flags: ef, linkFlags: elf };
	if (node == null || node.kind != NodeKind.ObjectLiteral) return t;
	const e = nodeString(findObjField(node, "entry"));
	if (e.length > 0) { t.entry = e; }
	const c = nodeString(findObjField(node, "compiler"));
	if (c.length > 0) { t.compiler = c; }
	const f = nodeStringArray(findObjField(node, "flags"));
	if (f.length > 0) { t.flags = f; }
	const lf = nodeStringArray(findObjField(node, "linkFlags"));
	if (lf.length > 0) { t.linkFlags = lf; }
	return t;
}

// Extract CcSection from an ObjectLiteral node.
function extractCc(ccNode: Node): CcSection {
	const cc = defaultCcSection();
	if (ccNode == null || ccNode.kind != NodeKind.ObjectLiteral) return cc;
	const c = nodeString(findObjField(ccNode, "compiler"));
	if (c.length > 0) { cc.compiler = c; }
	const f = nodeStringArray(findObjField(ccNode, "flags"));
	if (f.length > 0) { cc.flags = f; }
	const lf = nodeStringArray(findObjField(ccNode, "linkFlags"));
	if (lf.length > 0) { cc.linkFlags = lf; }
	// Per-target overrides: targets: { "linux-x86_64": { compiler: "...", flags: [...] } }
	const targetsNode = findObjField(ccNode, "targets");
	if (targetsNode != null && targetsNode.kind == NodeKind.ObjectLiteral) {
		const od = targetsNode.data as ObjectLiteralData;
		let i = 0;
		while (i < od.keys.length && i < od.properties.length) {
			cc.targetKeys.push(od.keys[i]);
			cc.targetValues.push(extractCcTarget(od.properties[i]));
			i += 1;
		}
	}
	return cc;
}

// Extract BuildSection from an ObjectLiteral node.
function extractBuild(buildNode: Node | null): BuildSection {
	const bs = defaultBuildSection();
	if (buildNode == null) return bs;
	if (buildNode.kind != NodeKind.ObjectLiteral) {
		bs.cacheError = "build: must be an object literal";
		return bs;
	}
	const fields = buildNode.data as ObjectLiteralData;
	for (let i: int32 = 0; i < fields.keys.length; i += 1) {
		const key = fields.keys[i];
		const value = i < fields.properties.length ? fields.properties[i] : null;
		if (value != null && (value.kind == NodeKind.SpreadExpr ||
			value.kind == NodeKind.ComputedProperty)) {
			bs.cacheError = "build: spread and computed fields require direct literal declarations";
			return bs;
		}
		if (key != "cacheDir" && key != "globalCacheDir" && key != "globalCache" && key != "trimpath") continue;
		if (key == "globalCache" || key == "trimpath") {
			if (value == null || value.kind != NodeKind.BooleanLiteral) {
				bs.cacheError = `build.${key}: must be a boolean literal`;
				return bs;
			}
			if (key == "trimpath") bs.trimpath = nodeBool(value) == 1;
			else bs.globalCache = nodeBool(value) == 1;
			continue;
		}
		if (value == null || value.kind != NodeKind.StringLiteral) {
			bs.cacheError = `build.${key}: must be a non-empty string literal`;
			return bs;
		}
		const path = nodeString(value);
		const checked = validateCacheDirectory(path);
		if (!checked.ok) {
			bs.cacheError = `build.${key}: ${checked.error}`;
			return bs;
		}
		if (key == "cacheDir") bs.cacheDir = path;
		else bs.globalCacheDir = path;
	}
	const t = nodeString(findObjField(buildNode, "target"));
	if (t.length > 0) { bs.target = (t == "native") ? "c" : t; }
	const od = nodeString(findObjField(buildNode, "outDir"));
	if (od.length > 0) { bs.outDir = od; }
	const of_ = nodeString(findObjField(buildNode, "outFile"));
	if (of_.length > 0) { bs.outFile = of_; }
	const opt = nodeString(findObjField(buildNode, "optimize"));
	if (opt.length > 0) { bs.optimize = opt; }
	return bs;
}

function extractConfigBuild(configObj: Node): BuildSection {
	const fields = configObj.data as ObjectLiteralData;
	let build = defaultBuildSection();
	let found = false;
	for (let i: int32 = 0; i < fields.keys.length; i += 1) {
		const value = i < fields.properties.length ? fields.properties[i] : null;
		if (value != null && (value.kind == NodeKind.SpreadExpr ||
			value.kind == NodeKind.ComputedProperty)) {
			build.cacheError = "build: configuration fields require direct literal declarations";
			return build;
		}
		if (fields.keys[i] != "build") continue;
		if (found) {
			build.cacheError = "build: duplicate build sections are not supported";
			return build;
		}
		found = true;
		build = extractBuild(value);
		if (build.cacheError != "") return build;
	}
	return build;
}

// Extract PackageSection from an ObjectLiteral node (the `package: { ... }` block).
function extractPackage(pkgNode: Node): PackageSection {
	const pkg = defaultPackageSection();
	if (pkgNode == null || pkgNode.kind != NodeKind.ObjectLiteral) return pkg;
	const n = nodeString(findObjField(pkgNode, "name"));
	if (n.length > 0) pkg.name = n;
	const v = nodeString(findObjField(pkgNode, "version"));
	if (v.length > 0) pkg.version = v;
	const desc = nodeString(findObjField(pkgNode, "description"));
	if (desc.length > 0) pkg.description = desc;
	const lic = nodeString(findObjField(pkgNode, "license"));
	if (lic.length > 0) pkg.license = lic;
	const repo = nodeString(findObjField(pkgNode, "repository"));
	if (repo.length > 0) pkg.repository = repo;
	const hp = nodeString(findObjField(pkgNode, "homepage"));
	if (hp.length > 0) pkg.homepage = hp;
	const auth = nodeString(findObjField(pkgNode, "author"));
	if (auth.length > 0) pkg.author = auth;
	const kwNode = findObjField(pkgNode, "keywords");
	if (kwNode != null) pkg.keywords = nodeStringArray(kwNode);
	const filesNode = findObjField(pkgNode, "files");
	if (filesNode != null) pkg.files = nodeStringArray(filesNode);
	const ignoreNode = findObjField(pkgNode, "ignore");
	if (ignoreNode != null) pkg.ignore = nodeStringArray(ignoreNode);
	const binNode = findObjField(pkgNode, "bin");
	if (binNode != null) pkg.bin = extractDeps(binNode);
	pkg.valid = pkg.name.length > 0;
	return pkg;
}

function extractGlobalImports(giNode: Node): string[] {
	const result: string[] = [];
	if (giNode == null || giNode.kind != NodeKind.ArrayLiteral) return result;
	const ad = giNode.data as ArrayLiteralData;
	for (const elem of ad.elements) {
		const flat = nodeString(elem);
		if (flat.length > 0) {
			result.push(flat);
		} else if (elem != null && elem.kind == NodeKind.ObjectLiteral) {
			const from = nodeString(findObjField(elem, "from"));
			if (from.length > 0) result.push(from);
		}
	}
	return result;
}

export function defaultDefinesSection(): DefinesSection {
	return { keys: [], values: [], refused: [] };
}

function extractDefines(node: Node): DefinesSection {
	const ds = defaultDefinesSection();
	if (node == null || node.kind != NodeKind.ObjectLiteral) return ds;
	const od = node.data as ObjectLiteralData;
	for (let i = 0; i < od.keys.length && i < od.properties.length; i += 1) {
		const value = od.properties[i];
		let text = "";
		let held = true;
		if (value != null && value.kind == NodeKind.StringLiteral) {
			text = nodeString(value);
		} else if (value != null && value.kind == NodeKind.NumberLiteral) {
			const n = value.data as NumberLiteralData;
			text = n.isFloat ? String(n.value) : String(n.intVal);
		} else if (nodeBool(value) >= 0) {
			text = nodeBool(value) == 1 ? "true" : "false";
		} else {
			held = false;
		}
		if (held) {
			ds.keys.push(od.keys[i]);
			ds.values.push(text);
		} else {
			ds.refused.push(od.keys[i]);
		}
	}
	return ds;
}

function extractModulePasses(giNode: Node, from: string[], macros: string[]): void {
	if (giNode == null || giNode.kind != NodeKind.ArrayLiteral) return;
	for (const elem of (giNode.data as ArrayLiteralData).elements) {
		if (elem == null || elem.kind != NodeKind.ObjectLiteral) continue;
		const macro = nodeString(findObjField(elem, "modulePass"));
		const src = nodeString(findObjField(elem, "from"));
		if (macro.length > 0 && src.length > 0) {
			from.push(src);
			macros.push(macro);
		}
	}
}

// Extract DepsSection from an ObjectLiteral node (the `deps: { ... }` or `devDeps: { ... }` block).
// Each key/value pair is a package name → version string (registry or git source spec).
function extractDeps(depsNode: Node): DepsSection {
	const ds = defaultDepsSection();
	if (depsNode == null || depsNode.kind != NodeKind.ObjectLiteral) return ds;
	const od = depsNode.data as ObjectLiteralData;
	let i = 0;
	while (i < od.keys.length) {
		const key = od.keys[i];
		const val = i < od.properties.length ? nodeString(od.properties[i]) : "";
		if (key.length > 0 && val.length > 0) {
			ds.keys.push(key);
			ds.values.push(val);
		}
		i = i + 1;
	}
	return ds;
}

let _parsersRegistered = false;

export function loadBuildConfig(filePath: string, showTime: boolean): BuildConfig {
	const defBs = defaultBuildSection();
	const defRs = defaultResolveSection();
	const defFmt = defaultFmtSection();
	const defLsp = defaultLspSection();
	const defCc = defaultCcSection();
	const defPkg = defaultPackageSection();
	const defDeps = defaultDepsSection();
	const defDevDeps = defaultDepsSection();
	const defGi: string[] = [];
	const defCfg: BuildConfig = { entry: "", build: defBs, resolve: defRs, fmt: defFmt, lsp: defLsp, cc: defCc, package: defPkg, deps: defDeps, devDeps: defDevDeps, globalImports: defGi, defines: defaultDefinesSection(), modulePassFrom: [], modulePassMacro: [], valid: false };

	if (!exists(filePath)) return defCfg;

	const read = readFile(filePath);
	if (!read.ok) {
		defBs.cacheError = `build: cannot read configuration: ${read.error.message}`;
		return defCfg;
	}
	const source = read.value;
	if (source.length == 0) {
		defBs.cacheError = "build: configuration is empty";
		return defCfg;
	}

	if (!_parsersRegistered) {
		registerCoreParsers();
		_parsersRegistered = true;
	}
	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		defBs.cacheError = "build: could not parse configuration";
		return defCfg;
	}

	const configObj = findConfigObject(parseResult.value);
	if (configObj == null) {
		defBs.cacheError = "build: configuration must contain an object literal";
		return defCfg;
	}

	const entry = nodeString(findObjField(configObj, "entry"));
	const bs = extractConfigBuild(configObj);
	const rs = extractResolve(findObjField(configObj, "resolve"));
	const fmt = extractFmt(findObjField(configObj, "fmt"));
	const lsp = extractLsp(findObjField(configObj, "lsp"));
	const cc = extractCc(findObjField(configObj, "cc"));
	const pkg = extractPackage(findObjField(configObj, "package"));
	const deps = extractDeps(findObjField(configObj, "deps"));
	const devDeps = extractDeps(findObjField(configObj, "devDeps"));

	const giNode = findObjField(configObj, "globalImports");
	const globalImports = extractGlobalImports(giNode);
	const defines = extractDefines(findObjField(configObj, "defines"));
	const modulePassFrom: string[] = [];
	const modulePassMacro: string[] = [];
	extractModulePasses(giNode, modulePassFrom, modulePassMacro);

	return { entry, build: bs, resolve: rs, fmt, lsp, cc, package: pkg, deps, devDeps, globalImports, defines, modulePassFrom, modulePassMacro, valid: true };
}

// Validate build.ms and return LSP-style warnings.
// Returns array of { message, line } for each issue found.
export interface BuildWarning {
	message: string;
	line: number;
}

// Parse build.ms source and return the config ObjectLiteral node, or null.
function parseBuildSource(source: string): Node | null {
	if (source.length == 0) return null;
	if (!_parsersRegistered) {
		registerCoreParsers();
		_parsersRegistered = true;
	}
	const parseResult = parseSource(source);
	if (!parseResult.ok) return null;
	return findConfigObject(parseResult.value);
}

export function validateBuildConfig(dir: string, source: string): BuildWarning[] {
	const warnings: BuildWarning[] = [];
	const configObj = parseBuildSource(source);
	if (configObj == null) return warnings;
	const buildNode = findObjField(configObj, "build");
	const build = extractConfigBuild(configObj);
	if (build.cacheError != "") {
		const line = buildNode == null ? configObj.location.line : buildNode.location.line;
		warnings.push({ message: build.cacheError, line });
	}
	const entryNode = findObjField(configObj, "entry");
	if (entryNode != null) {
		const entry = nodeString(entryNode);
		if (entry.length > 0) {
			// Use the module resolver to check entry — same extension lookup as build/run
			const buildFile = dir + "/build.ms";
			const candidates = resolveImportWithConfig(entry, buildFile, createDefaultConfig(Backend.C, dir));
			let found = false;
			for (const c of candidates) {
				if (exists(c)) { found = true; break; }
			}
			if (!found) {
				warnings.push({ message: `Entry '${entry}' not found — build/run may fail unless entry is provided via command args`, line: entryNode.location.line });
			}
		}
	}
	const lspNode = findObjField(configObj, "lsp");
	if (lspNode != null && lspNode.kind == NodeKind.ObjectLiteral) {
		const osNode = findObjField(lspNode, "os");
		if (osNode != null) {
			const osVal = nodeString(osNode);
			if (osVal != "bare" && osVal != "solana" && osVal != "wasm" && osVal != "emcc" && osVal != "linux" && osVal != "macos" && osVal != "windows" && osVal != "darwin" && osVal != "freebsd" && osVal != "ios" && osVal != "android") {
				warnings.push({ message: `lsp.os: unknown target '${osVal}' — valid: bare, solana, wasm, emcc, linux, macos, windows, darwin, freebsd, ios, android`, line: osNode.location.line });
			}
		}
		const gcNode = findObjField(lspNode, "gc");
		if (gcNode != null) {
			warnings.push({ message: "lsp.gc is gone: write lsp.mm (drc, manual or none)", line: gcNode.location.line });
		}
		const mmNode = findObjField(lspNode, "mm");
		if (mmNode != null) {
			const mmVal = nodeString(mmNode);
			if (mmVal != "none" && mmVal != "manual" && mmVal != "drc") {
				warnings.push({ message: `lsp.mm: unknown mode '${mmVal}' — valid: drc, manual, none`, line: mmNode.location.line });
			}
		}
	}
	return warnings;
}

// Load only the fmt section from build.ms at the given directory.
// Returns default if build.ms not found or has no fmt section.
export function loadFmtSection(dir: string): FmtSection {
	const buildPath = dir + "/build.ms";
	if (!exists(buildPath)) return defaultFmtSection();
	const fmtSource = try readFile(buildPath) catch "";
	if (fmtSource.length == 0) return defaultFmtSection();
	const configObj = parseBuildSource(fmtSource);
	if (configObj == null) return defaultFmtSection();
	return extractFmt(findObjField(configObj, "fmt"));
}

// Load only the lsp section from build.ms at the given directory.
// Returns default (empty os/gc = host platform, inferred gc) if absent or unparseable.
export function loadLspSection(dir: string): LspSection {
	const buildPath = dir + "/build.ms";
	if (!exists(buildPath)) return defaultLspSection();
	const lspSource = try readFile(buildPath) catch "";
	if (lspSource.length == 0) return defaultLspSection();
	const configObj = parseBuildSource(lspSource);
	if (configObj == null) return defaultLspSection();
	return extractLsp(findObjField(configObj, "lsp"));
}

// ===== Tests — package/deps extraction =====

function testExtractFromSource(source: string): BuildConfig {
	registerCoreParsers();
	_parsersRegistered = true;
	const configObj = parseBuildSource(source);
	if (configObj == null) {
		return {
			entry: "", build: defaultBuildSection(),
			resolve: defaultResolveSection(), fmt: defaultFmtSection(), lsp: defaultLspSection(), cc: defaultCcSection(),
			package: defaultPackageSection(), deps: defaultDepsSection(), devDeps: defaultDepsSection(),
			globalImports: [], defines: defaultDefinesSection(), modulePassFrom: [], modulePassMacro: [], valid: false,
		};
	}
	const entry = nodeString(findObjField(configObj, "entry"));
	const pkg = extractPackage(findObjField(configObj, "package"));
	const deps = extractDeps(findObjField(configObj, "deps"));
	const devDeps = extractDeps(findObjField(configObj, "devDeps"));
	const passFrom: string[] = [];
	const passMacro: string[] = [];
	extractModulePasses(findObjField(configObj, "globalImports"), passFrom, passMacro);
	return {
		entry, build: extractConfigBuild(configObj),
		resolve: extractResolve(findObjField(configObj, "resolve")),
		fmt: extractFmt(findObjField(configObj, "fmt")),
		lsp: extractLsp(findObjField(configObj, "lsp")),
		cc: extractCc(findObjField(configObj, "cc")),
		package: pkg, deps, devDeps,
		globalImports: extractGlobalImports(findObjField(configObj, "globalImports")),
		defines: extractDefines(findObjField(configObj, "defines")),
		modulePassFrom: passFrom, modulePassMacro: passMacro,
		valid: true,
	};
}

test "extractPackage reads name and version" {
	const cfg = testExtractFromSource("const config = { package: { name: \"my-app\", version: \"0.1.0\" } }; export default config;");
	assert cfg.valid;
	assert cfg.package.valid;
	assert cfg.package.name == "my-app";
	assert cfg.package.version == "0.1.0";
}

test "extractPackage reads all fields" {
	const src = "const config = { package: { name: \"x\", version: \"1.0.0\", description: \"A lib\", license: \"MIT\", repository: \"https://github.com/a/b\", homepage: \"https://x.dev\", author: \"Me\" } }; export default config;";
	const cfg = testExtractFromSource(src);
	assert cfg.package.description == "A lib";
	assert cfg.package.license == "MIT";
	assert cfg.package.repository == "https://github.com/a/b";
	assert cfg.package.homepage == "https://x.dev";
	assert cfg.package.author == "Me";
}

test "extractPackage invalid when no name" {
	const cfg = testExtractFromSource("const config = { package: { version: \"1.0.0\" } }; export default config;");
	assert !cfg.package.valid;
}

test "extractDeps reads key-value pairs" {
	const cfg = testExtractFromSource("const config = { deps: { \"cool-json\": \"1.2.3\", \"http-util\": \"2.0.1\" } }; export default config;");
	assert cfg.deps.keys.length == 2;
	assert cfg.deps.keys[0] == "cool-json";
	assert cfg.deps.values[0] == "1.2.3";
	assert cfg.deps.keys[1] == "http-util";
	assert cfg.deps.values[1] == "2.0.1";
}

test "extractDeps handles git source specs" {
	const cfg = testExtractFromSource("const config = { deps: { \"my-fork\": \"git+github.com/me/foo@v1.0.0\" } }; export default config;");
	assert cfg.deps.keys.length == 1;
	assert cfg.deps.keys[0] == "my-fork";
	assert cfg.deps.values[0] == "git+github.com/me/foo@v1.0.0";
}

test "extractGlobalImports reads flat string array" {
	const cfg = testExtractFromSource("const config = { globalImports: [\"./src/converters\"] }; export default config;");
	assert cfg.globalImports.length == 1;
	assert cfg.globalImports[0] == "./src/converters";
}

test "a globalImports entry naming a modulePass is both a global import and a pass" {
	const cfg = testExtractFromSource("const config = { globalImports: [\"./a\", { from: \"./src/refresh\", modulePass: \"refreshModule\" }, { from: \"./b\" }] }; export default config;");
	assert cfg.globalImports.length == 3;
	assert cfg.globalImports[1] == "./src/refresh";
	assert cfg.modulePassFrom.length == 1;
	assert cfg.modulePassFrom[0] == "./src/refresh";
	assert cfg.modulePassMacro[0] == "refreshModule";
}

test "a build without modulePass entries has no passes" {
	const cfg = testExtractFromSource("const config = { globalImports: [{ from: \"./src/converters\" }] }; export default config;");
	assert cfg.modulePassFrom.length == 0;
	assert cfg.modulePassMacro.length == 0;
}

test "extractGlobalImports reads from-object entries" {
	const cfg = testExtractFromSource("const config = { globalImports: [{ from: \"./src/converters\" }, { from: \"std/core/math\" }] }; export default config;");
	assert cfg.globalImports.length == 2;
	assert cfg.globalImports[0] == "./src/converters";
	assert cfg.globalImports[1] == "std/core/math";
}

test "extractGlobalImports mixes flat and from-object" {
	const cfg = testExtractFromSource("const config = { globalImports: [\"./a\", { from: \"./b\" }] }; export default config;");
	assert cfg.globalImports.length == 2;
	assert cfg.globalImports[0] == "./a";
	assert cfg.globalImports[1] == "./b";
}

test "extractGlobalImports absent yields empty" {
	const cfg = testExtractFromSource("const config = { entry: \"./src/index\" }; export default config;");
	assert cfg.globalImports.length == 0;
}

test "extractLsp reads os and mm" {
	const cfg = testExtractFromSource("const config = { lsp: { os: \"bare\", mm: \"manual\" } }; export default config;");
	assert cfg.lsp.os == "bare";
	assert cfg.lsp.mm == "manual";
}

test "extractLsp absent yields defaults" {
	const cfg = testExtractFromSource("const config = { entry: \"./src/index\" }; export default config;");
	assert cfg.lsp.os == "";
	assert cfg.lsp.mm == "";
}

test "extractLsp partial fields" {
	const cfg = testExtractFromSource("const config = { lsp: { os: \"solana\" } }; export default config;");
	assert cfg.lsp.os == "solana";
	assert cfg.lsp.mm == "";
}

test "validateBuildConfig flags bad lsp.os and lsp.mm, and lsp.gc as gone" {
	const src = "const config = { lsp: { os: \"bar\", mm: \"orc\" } }; export default config;";
	assert validateBuildConfig(".", src).length == 2;
	const old = validateBuildConfig(".", "const config = { lsp: { gc: \"manual\" } }; export default config;");
	assert old.length == 1;
	assert old[0].message == "lsp.gc is gone: write lsp.mm (drc, manual or none)";
}

test "validateBuildConfig accepts valid lsp values" {
	const src = "const config = { lsp: { os: \"bare\", mm: \"manual\" } }; export default config;";
	const warnings = validateBuildConfig(".", src);
	assert warnings.length == 0;
}

test "targetMemoryMode: solana is manual, bare is manual unless asked, the rest drc unless asked" {
	assert targetMemoryMode("solana", "") == "manual";
	assert targetMemoryMode("solana", "drc") == "manual";
	assert targetMemoryMode("solana", "none") == "none";
	assert targetMemoryMode("bare", "") == "manual";
	assert targetMemoryMode("bare", "drc") == "drc";
	assert targetMemoryMode("linux", "") == "drc";
	assert targetMemoryMode("macos", "manual") == "manual";
}

test "extractDeps empty block" {
	const cfg = testExtractFromSource("const config = { deps: {} }; export default config;");
	assert cfg.deps.keys.length == 0;
}

test "extractDeps no deps block" {
	const cfg = testExtractFromSource("const config = { entry: \"./src/index\" }; export default config;");
	assert cfg.deps.keys.length == 0;
}

test "devDeps separate from deps" {
	const cfg = testExtractFromSource("const config = { deps: { \"a\": \"1.0.0\" }, devDeps: { \"b\": \"0.1.0\" } }; export default config;");
	assert cfg.deps.keys.length == 1;
	assert cfg.deps.keys[0] == "a";
	assert cfg.devDeps.keys.length == 1;
	assert cfg.devDeps.keys[0] == "b";
	assert cfg.devDeps.values[0] == "0.1.0";
}

test "full manifest with entry + package + deps + devDeps" {
	const src = "const config = { entry: \"./src/index\", package: { name: \"my-app\", version: \"0.1.0\" }, deps: { \"foo\": \"1.2.3\" }, devDeps: { \"bar\": \"0.3.0\" } }; export default config;";
	const cfg = testExtractFromSource(src);
	assert cfg.valid;
	assert cfg.entry == "./src/index";
	assert cfg.package.name == "my-app";
	assert cfg.package.version == "0.1.0";
	assert cfg.deps.keys.length == 1;
	assert cfg.deps.values[0] == "1.2.3";
	assert cfg.devDeps.keys.length == 1;
	assert cfg.devDeps.values[0] == "0.3.0";
}

test "extractPackage keywords array" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\", keywords: [\"json\", \"parser\"] } }; export default config;");
	assert cfg.package.keywords.length == 2;
	assert cfg.package.keywords[0] == "json";
	assert cfg.package.keywords[1] == "parser";
}

test "extractPackage files array" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\", files: [\"src/**/*.ms\", \"README.md\"] } }; export default config;");
	assert cfg.package.files.length == 2;
	assert cfg.package.files[0] == "src/**/*.ms";
	assert cfg.package.files[1] == "README.md";
}

test "extractPackage ignore array" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\", ignore: [\"src/internal/**\", \"**/*_test.ms\"] } }; export default config;");
	assert cfg.package.ignore.length == 2;
	assert cfg.package.ignore[0] == "src/internal/**";
	assert cfg.package.ignore[1] == "**/*_test.ms";
}

test "extractPackage files + ignore together" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\", files: [\"src/**\"], ignore: [\"src/dev/**\"] } }; export default config;");
	assert cfg.package.files.length == 1;
	assert cfg.package.ignore.length == 1;
}

test "extractPackage files/ignore default empty" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\" } }; export default config;");
	assert cfg.package.files.length == 0;
	assert cfg.package.ignore.length == 0;
}

test "extractPackage bin map" {
	const cfg = testExtractFromSource("const config = { package: { name: \"ion\", version: \"1.0.0\", bin: { \"ion-generate\": \"tooling/generator/cli.ms\" } } }; export default config;");
	assert cfg.package.bin.keys.length == 1;
	assert cfg.package.bin.keys[0] == "ion-generate";
	assert cfg.package.bin.values[0] == "tooling/generator/cli.ms";
}

test "extractPackage bin holds every declared command" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\", bin: { \"a\": \"a.ms\", \"b\": \"b.ms\" } } }; export default config;");
	assert cfg.package.bin.keys.length == 2;
	assert cfg.package.bin.keys[1] == "b";
}

test "extractPackage bin defaults empty" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\" } }; export default config;");
	assert cfg.package.bin.keys.length == 0;
}

test "build cache fields preserve literals and independent sharing policy" {
	const cfg = testExtractFromSource(
		'const config = { build: { cacheDir: "local", globalCacheDir: "shared", ' +
		'globalCache: false } }; export default config;',
	);
	assert cfg.build.cacheError == "";
	assert cfg.build.cacheDir == "local";
	assert cfg.build.globalCacheDir == "shared";
	assert !cfg.build.globalCache;
	const enabled = testExtractFromSource(
		'const config = { build: { globalCache: true } }; export default config;',
	);
	assert enabled.build.globalCache;
	assert enabled.build.cacheError == "";
}

test "build trimpath is a boolean literal and defaults off" {
	assert !testExtractFromSource("const config = { build: {} };").build.trimpath;
	const on = testExtractFromSource("const config = { build: { trimpath: true } };");
	assert on.build.cacheError == "" && on.build.trimpath;
	for (const value of ['"true"', "null", "1", "enabled", "!true"]) {
		const cfg = testExtractFromSource(`const config = { build: { trimpath: ${value} } };`);
		assert cfg.build.cacheError.startsWith("build.trimpath:");
	}
}

test "omitted build cache fields remain unset and sharing defaults true" {
	for (const source of ["const config = {};", "const config = { build: {} };"]) {
		const cfg = testExtractFromSource(source);
		assert cfg.build.cacheDir == "";
		assert cfg.build.globalCacheDir == "";
		assert cfg.build.globalCache;
		assert cfg.build.cacheError == "";
	}
}

test "build cache paths refuse empty wrong-kind and nonliteral declarations" {
	for (const field of ["cacheDir", "globalCacheDir"]) {
		for (const value of ['""', "null", "42", "false", "[]", "{}", "path", '"a" + "b"']) {
			const cfg = testExtractFromSource(`const config = { build: { ${field}: ${value} } };`);
			assert cfg.build.cacheError.startsWith(`build.${field}:`);
		}
	}
}

test "build cache sharing refuses nonliteral booleans and a nonliteral build section" {
	for (const value of ['"false"', "null", "0", "enabled", "!false"]) {
		const cfg = testExtractFromSource(`const config = { build: { globalCache: ${value} } };`);
		assert cfg.build.cacheError.startsWith("build.globalCache:");
	}
	for (const value of ["null", "false", '"cache"', "settings", "[]"]) {
		const cfg = testExtractFromSource(`const config = { build: ${value} };`);
		assert cfg.build.cacheError == "build: must be an object literal";
	}
}

test "build cache paths refuse manifest control characters" {
	for (const field of ["cacheDir", "globalCacheDir"]) {
		for (const escape of ["\\0", "\\n", "\\r", "\\t", "\\v", "\\f"]) {
			const cfg = testExtractFromSource(
				`const config = { build: { ${field}: "a${escape}b" } };`,
			);
			assert cfg.build.cacheError.startsWith(`build.${field}:`);
		}
	}
	for (const path of ["a\u0085b", "a\u2028b", "a\u2029b"]) {
		assert !validateCacheDirectory(path).ok;
	}
}

test "a duplicate valid cache field cannot conceal an invalid declaration" {
	const cfg = testExtractFromSource(
		'const config = { build: { cacheDir: "valid", cacheDir: "" } };',
	);
	assert cfg.build.cacheError.startsWith("build.cacheDir:");
}

test "build cache declaration warnings expose the field and line" {
	const warnings = validateBuildConfig(
		".", 'const config = {\n build: { globalCache: "false" }\n};',
	);
	assert warnings.length == 1;
	assert warnings[0].message.startsWith("build.globalCache:");
	assert warnings[0].line == 2;
}

test "a malformed build file cannot silently select cache defaults" {
	const project = `out/test/buildCacheConfig${Date.now()}`;
	const file = project + "/build.ms";
	try {
		assert ensureDir(project).ok;
		for (const source of [
			'const config = { build: { cacheDir: "unfinished";',
			"const config = settings;",
		]) {
			assert writeFile(file, source).ok;
			const config = loadBuildConfig(file, false);
			assert config.build.cacheError.startsWith("build:");
		}
	} finally {
		removeAll(project);
	}
}

test "unextractable config keys cannot conceal cache declarations or disabled sharing" {
	for (const source of [
		'const config = { build: { ...{ cacheDir: "" } } };',
		"const config = { build: { ...{ globalCache: false } } };",
		'const config = { ...{ build: { cacheDir: "" } } };',
		'const config = { build: { ["cache" + "Dir"]: "" } };',
		'const config = { ["bu" + "ild"]: { globalCache: false } };',
	]) {
		assert testExtractFromSource(source).build.cacheError != "";
	}
}

test "duplicate build sections cannot conceal a cache declaration" {
	for (const section of ['cacheDir: ""', "globalCache: false"]) {
		const source = `const config = { build: {}, build: { ${section} } };`;
		assert testExtractFromSource(source).build.cacheError != "";
	}
}

test "an exported config is not replaced by an unrelated object" {
	for (const declaration of ['cacheDir: ""', "globalCache: false"]) {
		const cfg = testExtractFromSource(
			`const config = { build: { ${declaration} } }; const helper = {}; export default config;`,
		);
		if (declaration.startsWith("cacheDir")) assert cfg.build.cacheError != "";
		else assert !cfg.build.globalCache;
	}
}

test "a default object config and literal computed keys retain their static meaning" {
	const cfg = testExtractFromSource(
		'const helper = {}; export default { build: { ["globalCache"]: false } };',
	);
	assert cfg.valid && cfg.build.cacheError == "";
	assert !cfg.build.globalCache;
}

test "a present empty or unreadable configuration cannot select defaults" {
	const project = `out/test/emptyBuildCacheConfig${Date.now()}`;
	const file = project + "/build.ms";
	try {
		assert ensureDir(project).ok;
		assert writeFile(file, "").ok;
		assert loadBuildConfig(file, false).build.cacheError != "";
		assert removeAll(file).ok;
		assert ensureDir(file).ok;
		assert loadBuildConfig(file, false).build.cacheError != "";
	} finally {
		removeAll(project);
	}
}
