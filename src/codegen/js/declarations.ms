// JavaScript Codegen — Declaration Emitters

import {
	Node, NodeKind, NodeFlag, DeclKind,
	FunctionDeclData, EnumDeclData,
	ClassDeclData, PropertyDeclData, MethodDeclData, ConstructorDeclData,
	ImportDeclData, ExportDeclData, VariableDeclData,
	DecoratedDeclData,
} from "../../ast/node";
import { emit, emitNode, emitIndent, emitNewline, emitLine, JSGenerator, convertImportPath, emitJoinedStrings, emitJoinedSafeStrings, emitBodyOrEmpty } from "./emit";
import { safeJsName } from "./expressions";

// ===== Function Declaration =====

function emitFunctionDeclInner(gen: JSGenerator, node: Node): void {
	const d = node.data as FunctionDeclData;
	match (d.fnFlags) {
		"async" => { emit(gen, "async function "); },
		"generator" => { emit(gen, "function* "); },
		"async_generator" => { emit(gen, "async function* "); },
		_ => { emit(gen, "function "); },
	};
	emit(gen, safeJsName(d.fnName));
	emit(gen, "(");
	emitJoinedSafeStrings(gen, d.params, ", ", safeJsName);
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.fnBody);
	emitNewline(gen);
}

// Check if fnFlags contains "extern" (may also have gen:/ext: segments)
function isExternFlag(flags: string): boolean {
	if (flags === "extern") return true;
	if (flags.length < 6) return false;
	// Check for "extern|..." or "...|extern|..." or "...|extern"
	if (flags.startsWith("extern|")) return true;
	if (flags.indexOf("|extern|") >= 0) return true;
	if (flags.endsWith("|extern")) return true;
	return false;
}

export function emitFunctionDecl(gen: JSGenerator, node: Node): void {
	// Skip extern functions — they're type declarations, not runtime code.
	// The actual implementation comes from @import (e.g., node:process).
	const d = node.data as FunctionDeclData;
	if (isExternFlag(d.fnFlags)) return;
	emitIndent(gen);
	emitFunctionDeclInner(gen, node);
}

// ===== Enum Declaration =====
// TypeScript IIFE pattern: var E; (function(E) { E[E["A"]=0]="A"; })(E || (E = {}));

function emitEnumDeclInner(gen: JSGenerator, node: Node): void {
	const d = node.data as EnumDeclData;
	if (gen.bundleMode) {
		// Bundle mode: flat constants (matches transform output of EnumName_Member)
		// + namespace object for cross-module import via __mod["..."].EnumName.Member
		for (let i = 0; i < d.enumMembers.length; i += 1) {
			emitIndent(gen);
			emit(gen, `var ${safeJsName(d.enumName)}_${d.enumMembers[i]} = ${i};\n`);
		}
		return;
	}
	// Non-bundle: TypeScript IIFE pattern
	emit(gen, "var ");
	emit(gen, d.enumName);
	emit(gen, ";\n");
	emitIndent(gen);
	emit(gen, "(function (");
	emit(gen, d.enumName);
	emit(gen, ") {\n");
	gen.indentLevel = gen.indentLevel + 1;
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		emitIndent(gen);
		emit(gen, d.enumName);
		emit(gen, "[");
		emit(gen, d.enumName);
		emit(gen, "[\"");
		emit(gen, d.enumMembers[i]);
		emit(gen, "\"] = ");
		emit(gen, "" + i);
		emit(gen, "] = \"");
		emit(gen, d.enumMembers[i]);
		emit(gen, "\";\n");
	}
	gen.indentLevel = gen.indentLevel - 1;
	emitIndent(gen);
	emit(gen, "})(");
	emit(gen, d.enumName);
	emit(gen, " || (");
	emit(gen, d.enumName);
	emit(gen, " = {}));\n");
}

export function emitEnumDecl(gen: JSGenerator, node: Node): void {
	emitIndent(gen);
	emitEnumDeclInner(gen, node);
}

// ===== Class Declaration =====

function emitClassDeclInner(gen: JSGenerator, node: Node): void {
	const d = node.data as ClassDeclData;
	emit(gen, "class ");
	emit(gen, d.className);
	if (d.classExtends !== "") {
		emit(gen, " extends ");
		emit(gen, d.classExtends);
	}
	emit(gen, " {\n");
	gen.indentLevel = gen.indentLevel + 1;
	for (const member of d.classBody) {
		match (member.kind) {
			NodeKind.MethodDecl => { emitMethodDecl(gen, member); },
			NodeKind.ConstructorDecl => { emitConstructorDecl(gen, member); },
			NodeKind.PropertyDecl => {},
			_ => { emitNode(gen, member); },
		};
	}
	gen.indentLevel = gen.indentLevel - 1;
	emitIndent(gen);
	emit(gen, "}\n");
}

export function emitClassDecl(gen: JSGenerator, node: Node): void {
	// Extern class: native JS type — skip emission entirely
	if ((node.flags & NodeFlag.ExternC) !== 0) return;
	emitIndent(gen);
	emitClassDeclInner(gen, node);
}

// ===== Method Declaration =====

// Strip leading "this" from param list — JS class methods have implicit this.
function skipThisParams(params: string[]): string[] {
	if (params.length > 0 && params[0] === "this") {
		const result: string[] = [];
		for (let i = 1; i < params.length; i += 1) { result.push(params[i]); }
		return result;
	}
	return params;
}

export function emitMethodDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as MethodDeclData;
	emitIndent(gen);
	if (d.methodIsStatic) { emit(gen, "static "); }
	match (d.methodFlags) {
		"async" => { emit(gen, "async "); },
		"generator" => { emit(gen, "*"); },
		"async_generator" => { emit(gen, "async *"); },
		_ => {},
	};
	emit(gen, d.methodName);
	emit(gen, "(");
	emitJoinedSafeStrings(gen, skipThisParams(d.methodParams), ", ", safeJsName);
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.methodBody);
	emitNewline(gen);
}

// ===== Constructor Declaration =====

export function emitConstructorDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as ConstructorDeclData;
	emitIndent(gen);
	emit(gen, "constructor(");
	emitJoinedSafeStrings(gen, d.ctorParams, ", ", safeJsName);
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.ctorBody);
	emitNewline(gen);
}

// ===== Import Declaration =====

export function emitImportDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as ImportDeclData;
	if (gen.bundleMode) {
		// All modules in global scope — skip all MetaScript imports (symbols already in scope)
		return;
		// Dedup: filter out names already imported in this IIFE (const can't redeclare)
		const dedupNames: string[] = [];
		const dedupAliases: string[] = [];
		for (let ni = 0; ni < d.importNames.length; ni += 1) {
			const localName = (ni < d.importAliases.length && d.importAliases[ni] !== "" && d.importAliases[ni] !== d.importNames[ni]) ? d.importAliases[ni] : d.importNames[ni];
			let dup = false;
			for (const existing of gen.importedNames) { if (existing === localName) { dup = true; } }
			if (!dup) {
				dedupNames.push(d.importNames[ni]);
				dedupAliases.push(ni < d.importAliases.length ? d.importAliases[ni] : "");
				gen.importedNames.push(localName);
			}
		}
		if (dedupNames.length === 0) return;
		// Find module ID from the import source → module ID mapping
		let moduleId = d.importSource;
		for (let mi = 0; mi < gen.importSourceToModuleIdKeys.length; mi += 1) {
			if (gen.importSourceToModuleIdKeys[mi] === d.importSource) {
				moduleId = gen.importSourceToModuleId[mi];
			}
		}
		emitIndent(gen);
		emit(gen, "const { ");
		for (let i = 0; i < dedupNames.length; i += 1) {
			if (i > 0) emit(gen, ", ");
			const name = dedupNames[i];
			const alias = (i < dedupAliases.length && dedupAliases[i] !== "" && dedupAliases[i] !== name) ? dedupAliases[i] : "";
			emit(gen, name);
			if (alias !== "") { emit(gen, ": "); emit(gen, alias); }
		}
		emit(gen, ` } = __mod["${moduleId}"];\n`);
		return;
	}
	// Non-bundle mode: ES module import
	emitIndent(gen);
	if (d.importNames.length === 0) {
		emit(gen, "import \"");
		emit(gen, convertImportPath(d.importSource));
		emit(gen, "\";\n");
		return;
	}
	emit(gen, "import { ");
	for (let i = 0; i < d.importNames.length; i += 1) {
		if (i > 0) emit(gen, ", ");
		emit(gen, d.importNames[i]);
		if (i < d.importAliases.length && d.importAliases[i] !== "" && d.importAliases[i] !== d.importNames[i]) {
			emit(gen, " as ");
			emit(gen, d.importAliases[i]);
		}
	}
	emit(gen, " } from \"");
	emit(gen, convertImportPath(d.importSource));
	emit(gen, "\";\n");
}

// ===== Export Declaration =====

export function emitExportDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as ExportDeclData;
	const inner = d.exportedDecl;
	// Skip type-only exports (no JS output)
	if (inner.kind === NodeKind.InterfaceDecl) return;
	if (inner.kind === NodeKind.StructDecl) return;
	if (inner.kind === NodeKind.TypeAliasDecl) return;
	if (inner.kind === NodeKind.ExternDecl) return;
	// Skip extern functions — imported via @import, not compiled
	if (inner.kind === NodeKind.FunctionDecl && isExternFlag((inner.data as FunctionDeclData).fnFlags)) return;
	if (gen.bundleMode) {
		// Bundle mode: emit declaration without `export`, track exported name
		let exportName = "";
		if (inner.kind === NodeKind.FunctionDecl) { exportName = safeJsName((inner.data as FunctionDeclData).fnName); }
		else if (inner.kind === NodeKind.VariableDecl) { exportName = safeJsName((inner.data as VariableDeclData).declName); }
		else if (inner.kind === NodeKind.EnumDecl) { /* flat constants — no single variable to export */ }
		else if (inner.kind === NodeKind.ClassDecl) { exportName = safeJsName((inner.data as ClassDeclData).className); }
		if (exportName !== "") { gen.exportedNames.push(exportName); }
		// Emit the declaration itself (no export keyword)
		emitNode(gen, inner);
		return;
	}
	// Non-bundle: ES module export
	emitIndent(gen);
	emit(gen, "export ");
	match (inner.kind) {
		NodeKind.FunctionDecl => { emitFunctionDeclInner(gen, inner); },
		NodeKind.VariableDecl => {
			const vd = inner.data as VariableDeclData;
			match (vd.declKind) {
				DeclKind.Const => { emit(gen, "const "); },
				DeclKind.Var => { emit(gen, "var "); },
				_ => { emit(gen, "let "); },
			};
			emit(gen, safeJsName(vd.declName));
			if (vd.initializer !== null) {
				emit(gen, " = ");
				emitNode(gen, vd.initializer);
			}
			emit(gen, ";\n");
		},
		NodeKind.EnumDecl => { emitEnumDeclInner(gen, inner); },
		NodeKind.ClassDecl => { emitClassDeclInner(gen, inner); },
		_ => { emitNode(gen, inner); },
	};
}

// ===== Decorated Declaration =====

export function emitDecoratedDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as DecoratedDeclData;
	// Skip decorators, just emit the inner declaration
	emitNode(gen, d.decoratedNode);
}
