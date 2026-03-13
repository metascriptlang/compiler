// MetaScript Compiler CLI — build.ms config loader
// Uses AST parsing to extract config from build.ms (no Raiser VM needed).

import { readFile, fileExists } from "std/process";
import { registerCoreParsers } from "../parser/statements/core";
import { parseSource } from "../parser/statements/validation";
import {
	Node, NodeKind, ProgramData, VariableDeclData, ExportDeclData,
	ObjectLiteralData, NumberLiteralData, StringLiteralData, BooleanLiteralData,
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

export interface BuildConfig {
	root: string;
	build: BuildSection;
	resolve: ResolveSection;
	fmt: FmtSection;
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
	const defCfg: BuildConfig = { root: "", build: defBs, resolve: defRs, fmt: defFmt, valid: false };

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

	const root = nodeString(findObjField(configObj, "root"));
	const bs = extractBuild(findObjField(configObj, "build"));
	const fmt = extractFmt(findObjField(configObj, "fmt"));

	return { root, build: bs, resolve: defRs, fmt, valid: true };
}

// Load only the fmt section from build.ms at the given directory.
// Returns default if build.ms not found or has no fmt section.
export function loadFmtSection(dir: string): FmtSection {
	const buildPath = dir + "/build.ms";
	if (!fileExists(buildPath)) return defaultFmtSection();
	const source = readFile(buildPath);
	if (source.length === 0) return defaultFmtSection();
	if (!_parsersRegistered) {
		registerCoreParsers();
		_parsersRegistered = true;
	}
	const parseResult = parseSource(source);
	if (!parseResult.ok) return defaultFmtSection();
	const configObj = findConfigObject(parseResult.value);
	if (configObj === null) return defaultFmtSection();
	return extractFmt(findObjField(configObj, "fmt"));
}
