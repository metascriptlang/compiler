// JavaScript Codegen — Declaration Emitters

import {
	Node, NodeKind, NodeFlag, DeclKind, TypeKind, FunctionDeclData, EnumDeclData, ClassDeclData, MethodDeclData,
	ConstructorDeclData, ImportDeclData, ExportDeclData, VariableDeclData, DecoratedDeclData,
} from "../../ast/node";
import { emit, emitNode, emitIndent, emitNewline, JSGenerator, convertImportPath, emitJoinedSafeStrings, emitBodyOrEmpty } from "./emit";
import { safeJsName, jsSymbolName } from "./expressions";

// ===== Function Declaration =====

function emitFunctionDeclInner(gen: JSGenerator, node: Node): void {
	const d = node.data as FunctionDeclData;
	match (d.fnFlags) {
		"async" => { emit(gen, "async function "); },
		"generator" => { emit(gen, "function* "); },
		"async_generator" => { emit(gen, "async function* "); },
		_ => { emit(gen, "function "); },
	};
	emit(gen, jsSymbolName(node.resolvedSym, d.fnName, gen.bundleMode));
	emit(gen, "(");
	const savedThisName = gen.thisName;
	if (d.params.length > 0 && d.params[0] === "this") { gen.thisName = "$this"; }
	emitJoinedSafeStrings(gen, d.params, ", ", receiverSafeJsName);
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.fnBody);
	gen.thisName = savedThisName;
	emitNewline(gen);
}

function receiverSafeJsName(name: string): string {
	return name === "this" ? "$this" : safeJsName(name);
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
	// Tier 1: body-less overload signatures are typecheck-only, skip emission
	if (d.fnFlags.indexOf("overload", 0) >= 0) return;
	emitIndent(gen);
	emitFunctionDeclInner(gen, node);
}

// ===== Enum Declaration =====
// TypeScript IIFE pattern: var E; (function(E) { E[E["A"]=0]="A"; })(E || (E = {}));

function emitEnumDeclInner(gen: JSGenerator, node: Node): void {
	const d = node.data as EnumDeclData;
	// Flat constants matching the checker's `EnumName_Member` rewrite, in both
	// bundle and non-bundle output. The IIFE `E.Member` object form is never
	// referenced — the checker lowers every `E.Member` access to `E_Member`.
	// Honor explicit values (enumValues), else fall back to ordinal index.
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		const val = (d.enumValues !== null && i < d.enumValues.length) ? d.enumValues[i] : i;
		if (i > 0) emitIndent(gen);
		emit(gen, `var ${safeJsName(d.enumName)}_${d.enumMembers[i]} = ${val};\n`);
	}
}

export function emitEnumDecl(gen: JSGenerator, node: Node): void {
	emitIndent(gen);
	emitEnumDeclInner(gen, node);
}

// ===== Class Declaration =====

function jsBaseClassName(node: Node, declaredName: string, bundleMode: boolean): string {
	const sym = node.resolvedSym;
	if (sym === null || sym.symbolType === null) return safeJsName(declaredName);
	let inner = sym.symbolType;
	if (inner.kind === TypeKind.Ref && inner.typeReturn !== null) inner = inner.typeReturn;
	if (inner.typeExtra === null || inner.typeExtra.sym === null) return safeJsName(declaredName);
	const parent = inner.typeExtra.sym;
	return jsSymbolName(parent, parent.name, bundleMode);
}

function emitClassDeclInner(gen: JSGenerator, node: Node): void {
	const d = node.data as ClassDeclData;
	emit(gen, "class ");
	emit(gen, jsSymbolName(node.resolvedSym, d.className, gen.bundleMode));
	if (d.classExtends !== "") {
		emit(gen, " extends ");
		emit(gen, jsBaseClassName(node, d.classExtends, gen.bundleMode));
	}
	emit(gen, " {\n");
	gen.indentLevel = gen.indentLevel + 1;
	const staticMethods: Node[] = [];
	for (const member of d.classBody) {
		match (member.kind) {
			NodeKind.MethodDecl => {
				if ((member.data as MethodDeclData).methodIsStatic) { staticMethods.push(member); }
				else { emitMethodDecl(gen, member); }
			},
			NodeKind.ConstructorDecl => { emitConstructorDecl(gen, member); },
			NodeKind.PropertyDecl => {},
			_ => { emitNode(gen, member); },
		};
	}
	gen.indentLevel = gen.indentLevel - 1;
	emitIndent(gen);
	emit(gen, "}\n");
	for (const member of staticMethods) {
		emitStaticMethodFn(gen, d.className, member);
	}
}

function emitStaticMethodFn(gen: JSGenerator, className: string, member: Node): void {
	const d = member.data as MethodDeclData;
	if (isExternFlag(d.methodFlags)) return;
	if (d.methodFlags.indexOf("overload", 0) >= 0) return;
	emitIndent(gen);
	match (d.methodFlags) {
		"async" => { emit(gen, "async function "); },
		"generator" => { emit(gen, "function* "); },
		"async_generator" => { emit(gen, "async function* "); },
		_ => { emit(gen, "function "); },
	};
	emit(gen, jsSymbolName(member.resolvedSym, className + "_" + d.methodName, gen.bundleMode));
	emit(gen, "(");
	emitJoinedSafeStrings(gen, skipThisParams(d.methodParams), ", ", safeJsName);
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.methodBody);
	emitNewline(gen);
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
	if (isExternFlag(d.methodFlags)) return;
	if (d.methodFlags.indexOf("overload", 0) >= 0) return;
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
	// .h imports have no JavaScript counterpart — their extern decls are
	// inlined alongside the ImportDecl by inlineHeaderImports, and the JS
	// backend doesn't consume C headers. Skip emission entirely.
	if (d.importSource.length >= 2 && d.importSource.slice(d.importSource.length - 2, d.importSource.length) === ".h") return;
	// std/meta is the compile-time AST/macro API — no runtime JS counterpart.
	if (d.importSource === "std/meta" || (d.importSource.length >= 9 && d.importSource.slice(0, 9) === "std/meta/")) return;
	// Bundle: every module shares one flat scope and names carry module
	// identity, so cross-module references need no binding statement.
	if (gen.bundleMode) return;
	// Non-bundle mode: ES module import
	emitIndent(gen);
	if (d.importNames.length === 0) {
		emit(gen, "import \"");
		emit(gen, convertImportPath(d.importSource));
		emit(gen, "\";\n");
		return;
	}
	// Namespace import: import * as ns from "path"
	if (d.importNames.length === 1 && d.importNames[0] === "*") {
		emit(gen, "import * as ");
		emit(gen, d.importAliases[0]);
		emit(gen, " from \"");
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
	// Star re-export: export * from "path"
	if (inner.kind === NodeKind.ImportDecl) {
		const imp = inner.data as ImportDeclData;
		if (imp.importNames.length === 1 && imp.importNames[0] === "*") {
			if (!gen.bundleMode) {
				emitIndent(gen);
				emit(gen, "export * from \"");
				emit(gen, convertImportPath(imp.importSource));
				emit(gen, "\";\n");
			}
			return;
		}
	}
	// Skip type-only exports (no JS output)
	if (inner.kind === NodeKind.InterfaceDecl) return;
	if (inner.kind === NodeKind.StructDecl) return;
	if (inner.kind === NodeKind.TypeAliasDecl) return;
	if (inner.kind === NodeKind.ExternDecl) return;
	// Compile-time-only — no runtime JS (mirrors the bare-decl skip in jsgen.ms)
	if (inner.kind === NodeKind.MacroDecl) return;
	if (inner.kind === NodeKind.ComptimeBlock) return;
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
