// MetaScript Compiler CLI — build.ms config loader
// Uses AST parsing to extract config from build.ms (no Raiser VM needed).

import { platform } from "std/process";
import { exists, readFile } from "std/fs";
import { registerCoreParsers } from "../parser/statements/core";
import { parseSource } from "../parser/statements/validation";
import { resolveImportWithConfig, createDefaultConfig, Backend } from "../module/resolver";
import {
	Node, NodeKind, ProgramData, VariableDeclData, ExportDeclData,
	ObjectLiteralData, ArrayLiteralData, NumberLiteralData, StringLiteralData, BooleanLiteralData,
} from "../ast/node";

// --- Interfaces ---

export interface BuildSection {
	target: string;
	outDir: string;
	outFile: string;
	optimize: string;
}

export interface ResolveSection {
	searchPaths: string[];
	extensions: string[];
	aliasKeys: string[];
	aliasValues: string[];
}

export interface FmtSection {
	printWidth: number;
	tabWidth: number;
	useTabs: number;        // -1 = unset, 0 = false, 1 = true
	singleQuote: number;    // -1 = unset, 0 = false, 1 = true
}

export function defaultFmtSection(): FmtSection {
	return { printWidth: -1, tabWidth: -1, useTabs: -1, singleQuote: -1 };
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
	if (key === "linux-amd64") return "x86_64-unknown-linux-gnu-gcc";
	if (key === "linux-arm64") return "aarch64-unknown-linux-gnu-gcc";
	if (key === "linux-386") return "i686-unknown-linux-gnu-gcc";
	if (key === "linux-riscv64") return "riscv64-unknown-linux-gnu-gcc";
	if (key === "linux-mips64") return "mips64-unknown-linux-gnu-gcc";
	if (key === "windows-amd64") return "x86_64-w64-mingw32-gcc";
	if (key === "windows-386") return "i686-w64-mingw32-gcc";
	if (key === "windows-arm64") return "aarch64-w64-mingw32-gcc";
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

	if (targetOs !== platform || cpuTarget !== "") {
		const key = `${targetOs}-${cpuTarget}`;
		let i = 0;
		while (i < cc.targetKeys.length) {
			if (cc.targetKeys[i] === key) {
				const t = cc.targetValues[i];
				if (t.entry !== "") entry = t.entry;
				if (t.compiler !== "") compiler = t.compiler;
				if (t.flags.length > 0) flags = t.flags;
				if (t.linkFlags.length > 0) linkFlags = t.linkFlags;
				break;
			}
			i += 1;
		}
		// Fallback to well-known cross-compiler if nothing configured
		if (compiler === "") {
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
	valid: boolean;         // false if no `package` block present
}

export function defaultPackageSection(): PackageSection {
	const kw: string[] = [];
	const files: string[] = [];
	const ignore: string[] = [];
	return { name: "", version: "", description: "", license: "", repository: "", homepage: "", keywords: kw, author: "", files, ignore, valid: false };
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
	cc: CcSection;
	package: PackageSection;
	deps: DepsSection;
	devDeps: DepsSection;
	globalImports: string[];
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
	if (resolveNode === null || resolveNode.kind !== NodeKind.ObjectLiteral) return rs;
	const aliasNode = findObjField(resolveNode, "alias");
	if (aliasNode !== null && aliasNode.kind === NodeKind.ObjectLiteral) {
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
	if (node === null || node.kind !== NodeKind.ObjectLiteral) return null as unknown as Node;
	const od = node.data as ObjectLiteralData;
	for (let i = 0; i < od.keys.length; i = i + 1) {
		if (od.keys[i] === key && i < od.properties.length) return od.properties[i];
	}
	return null as unknown as Node;
}

// Extract a string value from a node (StringLiteral only).
function nodeString(node: Node): string {
	if (node === null || node.kind !== NodeKind.StringLiteral) return "";
	return (node.data as StringLiteralData).value;
}

// Extract a number value from a node (NumberLiteral only).
function nodeNumber(node: Node): number {
	if (node === null || node.kind !== NodeKind.NumberLiteral) return -1;
	return (node.data as NumberLiteralData).value;
}

// Extract a string array from an ArrayLiteral node.
function nodeStringArray(node: Node): string[] {
	const result: string[] = [];
	if (node === null || node.kind !== NodeKind.ArrayLiteral) return result;
	const ad = node.data as ArrayLiteralData;
	for (const elem of ad.elements) {
		const s = nodeString(elem);
		if (s.length > 0) result.push(s);
	}
	return result;
}

// Extract a boolean value from a node. Returns -1 if not bool, 0 for false, 1 for true.
function nodeBool(node: Node): number {
	if (node === null || node.kind !== NodeKind.BooleanLiteral) return -1;
	return (node.data as BooleanLiteralData).boolValue ? 1 : 0;
}

// Find the root config ObjectLiteral from parsed build.ms AST.
// Handles: `const config = { ... }; export default config;`
// and:     `export default { ... };`
// and:     `export default defineConfig({ ... });`
function findConfigObject(program: Node): Node | null {
	if (program === null || program.kind !== NodeKind.Program) return null;
	const pd = program.data as ProgramData;
	let configObj: Node | null = null;

	// First pass: find top-level VariableDecl with ObjectLiteral init
	for (let i = 0; i < pd.programStmts.length; i = i + 1) {
		let stmt = pd.programStmts[i];
		// Unwrap export
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			stmt = ed.exportedDecl;
		}
		if (stmt.kind === NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			if (vd.initializer !== null && vd.initializer.kind === NodeKind.ObjectLiteral) {
				configObj = vd.initializer;
			}
		}
	}
	return configObj;
}

// Extract FmtSection from an ObjectLiteral node.
function extractFmt(fmtNode: Node): FmtSection {
	const fmt = defaultFmtSection();
	if (fmtNode === null || fmtNode.kind !== NodeKind.ObjectLiteral) return fmt;
	const pw = findObjField(fmtNode, "printWidth");
	if (pw !== null) { const v = nodeNumber(pw); if (v >= 0) { fmt.printWidth = v; } }
	const tw = findObjField(fmtNode, "tabWidth");
	if (tw !== null) { const v = nodeNumber(tw); if (v >= 0) { fmt.tabWidth = v; } }
	const ut = findObjField(fmtNode, "useTabs");
	if (ut !== null) { fmt.useTabs = nodeBool(ut); }
	const sq = findObjField(fmtNode, "singleQuote");
	if (sq !== null) { fmt.singleQuote = nodeBool(sq); }
	return fmt;
}

// Extract a CcTargetSection from an ObjectLiteral node.
function extractCcTarget(node: Node): CcTargetSection {
	const ef: string[] = [];
	const elf: string[] = [];
	const t: CcTargetSection = { entry: "", compiler: "", flags: ef, linkFlags: elf };
	if (node === null || node.kind !== NodeKind.ObjectLiteral) return t;
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
	if (ccNode === null || ccNode.kind !== NodeKind.ObjectLiteral) return cc;
	const c = nodeString(findObjField(ccNode, "compiler"));
	if (c.length > 0) { cc.compiler = c; }
	const f = nodeStringArray(findObjField(ccNode, "flags"));
	if (f.length > 0) { cc.flags = f; }
	const lf = nodeStringArray(findObjField(ccNode, "linkFlags"));
	if (lf.length > 0) { cc.linkFlags = lf; }
	// Per-target overrides: targets: { "linux-x86_64": { compiler: "...", flags: [...] } }
	const targetsNode = findObjField(ccNode, "targets");
	if (targetsNode !== null && targetsNode.kind === NodeKind.ObjectLiteral) {
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
function extractBuild(buildNode: Node): BuildSection {
	const bs: BuildSection = { target: "c", outDir: "out", outFile: "", optimize: "debug" };
	if (buildNode === null || buildNode.kind !== NodeKind.ObjectLiteral) return bs;
	const t = nodeString(findObjField(buildNode, "target"));
	if (t.length > 0) { bs.target = (t === "native") ? "c" : t; }
	const od = nodeString(findObjField(buildNode, "outDir"));
	if (od.length > 0) { bs.outDir = od; }
	const of_ = nodeString(findObjField(buildNode, "outFile"));
	if (of_.length > 0) { bs.outFile = of_; }
	const opt = nodeString(findObjField(buildNode, "optimize"));
	if (opt.length > 0) { bs.optimize = opt; }
	return bs;
}

// Extract PackageSection from an ObjectLiteral node (the `package: { ... }` block).
function extractPackage(pkgNode: Node): PackageSection {
	const pkg = defaultPackageSection();
	if (pkgNode === null || pkgNode.kind !== NodeKind.ObjectLiteral) return pkg;
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
	if (kwNode !== null) pkg.keywords = nodeStringArray(kwNode);
	const filesNode = findObjField(pkgNode, "files");
	if (filesNode !== null) pkg.files = nodeStringArray(filesNode);
	const ignoreNode = findObjField(pkgNode, "ignore");
	if (ignoreNode !== null) pkg.ignore = nodeStringArray(ignoreNode);
	pkg.valid = pkg.name.length > 0;
	return pkg;
}

function extractGlobalImports(giNode: Node): string[] {
	const result: string[] = [];
	if (giNode === null || giNode.kind !== NodeKind.ArrayLiteral) return result;
	const ad = giNode.data as ArrayLiteralData;
	for (const elem of ad.elements) {
		const flat = nodeString(elem);
		if (flat.length > 0) {
			result.push(flat);
		} else if (elem !== null && elem.kind === NodeKind.ObjectLiteral) {
			const from = nodeString(findObjField(elem, "from"));
			if (from.length > 0) result.push(from);
		}
	}
	return result;
}

// Extract DepsSection from an ObjectLiteral node (the `deps: { ... }` or `devDeps: { ... }` block).
// Each key/value pair is a package name → version string (registry or git source spec).
function extractDeps(depsNode: Node): DepsSection {
	const ds = defaultDepsSection();
	if (depsNode === null || depsNode.kind !== NodeKind.ObjectLiteral) return ds;
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
	const defBs: BuildSection = { target: "c", outDir: "out", outFile: "", optimize: "debug" };
	const defRs = defaultResolveSection();
	const defFmt = defaultFmtSection();
	const defCc = defaultCcSection();
	const defPkg = defaultPackageSection();
	const defDeps = defaultDepsSection();
	const defDevDeps = defaultDepsSection();
	const defGi: string[] = [];
	const defCfg: BuildConfig = { entry: "", build: defBs, resolve: defRs, fmt: defFmt, cc: defCc, package: defPkg, deps: defDeps, devDeps: defDevDeps, globalImports: defGi, valid: false };

	if (!exists(filePath)) return defCfg;

	const source = try readFile(filePath) catch "";
	if (source.length === 0) return defCfg;

	if (!_parsersRegistered) {
		registerCoreParsers();
		_parsersRegistered = true;
	}
	const parseResult = parseSource(source);
	if (!parseResult.ok) return defCfg;

	const configObj = findConfigObject(parseResult.value);
	if (configObj === null) return defCfg;

	const entry = nodeString(findObjField(configObj, "entry"));
	const bs = extractBuild(findObjField(configObj, "build"));
	const rs = extractResolve(findObjField(configObj, "resolve"));
	const fmt = extractFmt(findObjField(configObj, "fmt"));
	const cc = extractCc(findObjField(configObj, "cc"));
	const pkg = extractPackage(findObjField(configObj, "package"));
	const deps = extractDeps(findObjField(configObj, "deps"));
	const devDeps = extractDeps(findObjField(configObj, "devDeps"));

	const globalImports = extractGlobalImports(findObjField(configObj, "globalImports"));

	return { entry, build: bs, resolve: rs, fmt, cc, package: pkg, deps, devDeps, globalImports, valid: true };
}

// Validate build.ms and return LSP-style warnings.
// Returns array of { message, line } for each issue found.
export interface BuildWarning {
	message: string;
	line: number;
}

// Parse build.ms source and return the config ObjectLiteral node, or null.
function parseBuildSource(source: string): Node | null {
	if (source.length === 0) return null;
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
	if (configObj === null) return warnings;
	const entryNode = findObjField(configObj, "entry");
	if (entryNode !== null) {
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
	return warnings;
}

// Load only the fmt section from build.ms at the given directory.
// Returns default if build.ms not found or has no fmt section.
export function loadFmtSection(dir: string): FmtSection {
	const buildPath = dir + "/build.ms";
	if (!exists(buildPath)) return defaultFmtSection();
	const fmtSource = try readFile(buildPath) catch "";
	if (fmtSource.length === 0) return defaultFmtSection();
	const configObj = parseBuildSource(fmtSource);
	if (configObj === null) return defaultFmtSection();
	return extractFmt(findObjField(configObj, "fmt"));
}

// ===== Tests — package/deps extraction =====

function testExtractFromSource(source: string): BuildConfig {
	registerCoreParsers();
	_parsersRegistered = true;
	const configObj = parseBuildSource(source);
	if (configObj === null) {
		return {
			entry: "", build: { target: "c", outDir: "out", outFile: "", optimize: "debug" },
			resolve: defaultResolveSection(), fmt: defaultFmtSection(), cc: defaultCcSection(),
			package: defaultPackageSection(), deps: defaultDepsSection(), devDeps: defaultDepsSection(), valid: false,
		};
	}
	const entry = nodeString(findObjField(configObj, "entry"));
	const pkg = extractPackage(findObjField(configObj, "package"));
	const deps = extractDeps(findObjField(configObj, "deps"));
	const devDeps = extractDeps(findObjField(configObj, "devDeps"));
	return {
		entry, build: extractBuild(findObjField(configObj, "build")),
		resolve: extractResolve(findObjField(configObj, "resolve")),
		fmt: extractFmt(findObjField(configObj, "fmt")),
		cc: extractCc(findObjField(configObj, "cc")),
		package: pkg, deps, devDeps,
		globalImports: extractGlobalImports(findObjField(configObj, "globalImports")),
		valid: true,
	};
}

test "extractPackage reads name and version" {
	const cfg = testExtractFromSource("const config = { package: { name: \"my-app\", version: \"0.1.0\" } }; export default config;");
	assert cfg.valid;
	assert cfg.package.valid;
	assert cfg.package.name === "my-app";
	assert cfg.package.version === "0.1.0";
}

test "extractPackage reads all fields" {
	const src = "const config = { package: { name: \"x\", version: \"1.0.0\", description: \"A lib\", license: \"MIT\", repository: \"https://github.com/a/b\", homepage: \"https://x.dev\", author: \"Me\" } }; export default config;";
	const cfg = testExtractFromSource(src);
	assert cfg.package.description === "A lib";
	assert cfg.package.license === "MIT";
	assert cfg.package.repository === "https://github.com/a/b";
	assert cfg.package.homepage === "https://x.dev";
	assert cfg.package.author === "Me";
}

test "extractPackage invalid when no name" {
	const cfg = testExtractFromSource("const config = { package: { version: \"1.0.0\" } }; export default config;");
	assert !cfg.package.valid;
}

test "extractDeps reads key-value pairs" {
	const cfg = testExtractFromSource("const config = { deps: { \"cool-json\": \"1.2.3\", \"http-util\": \"2.0.1\" } }; export default config;");
	assert cfg.deps.keys.length === 2;
	assert cfg.deps.keys[0] === "cool-json";
	assert cfg.deps.values[0] === "1.2.3";
	assert cfg.deps.keys[1] === "http-util";
	assert cfg.deps.values[1] === "2.0.1";
}

test "extractDeps handles git source specs" {
	const cfg = testExtractFromSource("const config = { deps: { \"my-fork\": \"git+github.com/me/foo@v1.0.0\" } }; export default config;");
	assert cfg.deps.keys.length === 1;
	assert cfg.deps.keys[0] === "my-fork";
	assert cfg.deps.values[0] === "git+github.com/me/foo@v1.0.0";
}

test "extractGlobalImports reads flat string array" {
	const cfg = testExtractFromSource("const config = { globalImports: [\"./src/converters\"] }; export default config;");
	assert cfg.globalImports.length === 1;
	assert cfg.globalImports[0] === "./src/converters";
}

test "extractGlobalImports reads from-object entries" {
	const cfg = testExtractFromSource("const config = { globalImports: [{ from: \"./src/converters\" }, { from: \"std/core/math\" }] }; export default config;");
	assert cfg.globalImports.length === 2;
	assert cfg.globalImports[0] === "./src/converters";
	assert cfg.globalImports[1] === "std/core/math";
}

test "extractGlobalImports mixes flat and from-object" {
	const cfg = testExtractFromSource("const config = { globalImports: [\"./a\", { from: \"./b\" }] }; export default config;");
	assert cfg.globalImports.length === 2;
	assert cfg.globalImports[0] === "./a";
	assert cfg.globalImports[1] === "./b";
}

test "extractGlobalImports absent yields empty" {
	const cfg = testExtractFromSource("const config = { entry: \"./src/index\" }; export default config;");
	assert cfg.globalImports.length === 0;
}

test "extractDeps empty block" {
	const cfg = testExtractFromSource("const config = { deps: {} }; export default config;");
	assert cfg.deps.keys.length === 0;
}

test "extractDeps no deps block" {
	const cfg = testExtractFromSource("const config = { entry: \"./src/index\" }; export default config;");
	assert cfg.deps.keys.length === 0;
}

test "devDeps separate from deps" {
	const cfg = testExtractFromSource("const config = { deps: { \"a\": \"1.0.0\" }, devDeps: { \"b\": \"0.1.0\" } }; export default config;");
	assert cfg.deps.keys.length === 1;
	assert cfg.deps.keys[0] === "a";
	assert cfg.devDeps.keys.length === 1;
	assert cfg.devDeps.keys[0] === "b";
	assert cfg.devDeps.values[0] === "0.1.0";
}

test "full manifest with entry + package + deps + devDeps" {
	const src = "const config = { entry: \"./src/index\", package: { name: \"my-app\", version: \"0.1.0\" }, deps: { \"foo\": \"1.2.3\" }, devDeps: { \"bar\": \"0.3.0\" } }; export default config;";
	const cfg = testExtractFromSource(src);
	assert cfg.valid;
	assert cfg.entry === "./src/index";
	assert cfg.package.name === "my-app";
	assert cfg.package.version === "0.1.0";
	assert cfg.deps.keys.length === 1;
	assert cfg.deps.values[0] === "1.2.3";
	assert cfg.devDeps.keys.length === 1;
	assert cfg.devDeps.values[0] === "0.3.0";
}

test "extractPackage keywords array" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\", keywords: [\"json\", \"parser\"] } }; export default config;");
	assert cfg.package.keywords.length === 2;
	assert cfg.package.keywords[0] === "json";
	assert cfg.package.keywords[1] === "parser";
}

test "extractPackage files array" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\", files: [\"src/**/*.ms\", \"README.md\"] } }; export default config;");
	assert cfg.package.files.length === 2;
	assert cfg.package.files[0] === "src/**/*.ms";
	assert cfg.package.files[1] === "README.md";
}

test "extractPackage ignore array" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\", ignore: [\"src/internal/**\", \"**/*_test.ms\"] } }; export default config;");
	assert cfg.package.ignore.length === 2;
	assert cfg.package.ignore[0] === "src/internal/**";
	assert cfg.package.ignore[1] === "**/*_test.ms";
}

test "extractPackage files + ignore together" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\", files: [\"src/**\"], ignore: [\"src/dev/**\"] } }; export default config;");
	assert cfg.package.files.length === 1;
	assert cfg.package.ignore.length === 1;
}

test "extractPackage files/ignore default empty" {
	const cfg = testExtractFromSource("const config = { package: { name: \"x\", version: \"1.0.0\" } }; export default config;");
	assert cfg.package.files.length === 0;
	assert cfg.package.ignore.length === 0;
}
