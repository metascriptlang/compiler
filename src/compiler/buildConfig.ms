// MetaScript Compiler CLI — build.ms config loader
// Uses AST parsing to extract config from build.ms (no Raiser VM needed).

import { fileExists } from "std/process";
import { readFile } from "std/fs";
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
function defaultCompilerForTarget(osTarget: string, cpuTarget: string): string {
	const key = `${osTarget}-${cpuTarget}`;
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
export function resolveCcForTarget(cc: CcSection, osTarget: string, cpuTarget: string): CcTargetSection {
	let entry = "";
	let compiler = cc.compiler;
	let flags = cc.flags;
	let linkFlags = cc.linkFlags;

	if (osTarget !== "" || cpuTarget !== "") {
		const key = `${osTarget}-${cpuTarget}`;
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
			compiler = defaultCompilerForTarget(osTarget, cpuTarget);
		}
	}

	return { entry, compiler, flags, linkFlags };
}

export interface BuildConfig {
	entry: string;
	build: BuildSection;
	resolve: ResolveSection;
	fmt: FmtSection;
	cc: CcSection;
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
function findConfigObject(program: Node): Node {
	if (program === null || program.kind !== NodeKind.Program) return null as unknown as Node;
	const pd = program.data as ProgramData;
	let configObj: Node = null as unknown as Node;

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

let _parsersRegistered = false;

export function loadBuildConfig(filePath: string, showTime: boolean): BuildConfig {
	const defBs: BuildSection = { target: "c", outDir: "out", outFile: "", optimize: "debug" };
	const defRs = defaultResolveSection();
	const defFmt = defaultFmtSection();
	const defCc = defaultCcSection();
	const defCfg: BuildConfig = { entry: "", build: defBs, resolve: defRs, fmt: defFmt, cc: defCc, valid: false };

	if (!fileExists(filePath)) return defCfg;

	const source = readFile(filePath);
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
	const fmt = extractFmt(findObjField(configObj, "fmt"));
	const cc = extractCc(findObjField(configObj, "cc"));

	return { entry, build: bs, resolve: defRs, fmt, cc, valid: true };
}

// Validate build.ms and return LSP-style warnings.
// Returns array of { message, line } for each issue found.
export interface BuildWarning {
	message: string;
	line: number;
}

// Parse build.ms source and return the config ObjectLiteral node, or null.
function parseBuildSource(source: string): Node {
	if (source.length === 0) return null as unknown as Node;
	if (!_parsersRegistered) {
		registerCoreParsers();
		_parsersRegistered = true;
	}
	const parseResult = parseSource(source);
	if (!parseResult.ok) return null as unknown as Node;
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
				if (fileExists(c)) { found = true; break; }
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
	if (!fileExists(buildPath)) return defaultFmtSection();
	const source = readFile(buildPath);
	const configObj = parseBuildSource(source);
	if (configObj === null) return defaultFmtSection();
	return extractFmt(findObjField(configObj, "fmt"));
}
