// JavaScript Codegen — Declaration Emitters

import {
	Node, NodeKind, DeclKind,
	FunctionDeclData, EnumDeclData,
	ClassDeclData, PropertyDeclData, MethodDeclData, ConstructorDeclData,
	ImportDeclData, ExportDeclData, VariableDeclData,
	DecoratedDeclData,
} from "../../ast/node";
import { emit, emitNode, emitIndent, emitNewline, emitLine, JSGenerator, convertImportPath, emitJoinedStrings, emitBodyOrEmpty } from "./emit";
import { sliceStr } from "../../utils/string";

// ===== Function Declaration =====

function emitFunctionDeclInner(gen: JSGenerator, node: Node): void {
	const d = node.data as FunctionDeclData;
	if (d.fnFlags === "async") { emit(gen, "async function "); }
	else if (d.fnFlags === "generator") { emit(gen, "function* "); }
	else if (d.fnFlags === "async_generator") { emit(gen, "async function* "); }
	else { emit(gen, "function "); }
	emit(gen, d.fnName);
	emit(gen, "(");
	emitJoinedStrings(gen, d.params, ", ");
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.fnBody);
	emitNewline(gen);
}

export function emitFunctionDecl(gen: JSGenerator, node: Node): void {
	emitIndent(gen);
	emitFunctionDeclInner(gen, node);
}

// ===== Enum Declaration =====
// TypeScript IIFE pattern: var E; (function(E) { E[E["A"]=0]="A"; })(E || (E = {}));

function emitEnumDeclInner(gen: JSGenerator, node: Node): void {
	const d = node.data as EnumDeclData;
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
	for (let i = 0; i < d.classBody.length; i += 1) {
		const member = d.classBody[i];
		if (member.kind === NodeKind.MethodDecl) {
			emitMethodDecl(gen, member);
		} else if (member.kind === NodeKind.ConstructorDecl) {
			emitConstructorDecl(gen, member);
		} else if (member.kind === NodeKind.PropertyDecl) {
			// Skip type-only property declarations in JS
		} else {
			emitNode(gen, member);
		}
	}
	gen.indentLevel = gen.indentLevel - 1;
	emitIndent(gen);
	emit(gen, "}\n");
}

export function emitClassDecl(gen: JSGenerator, node: Node): void {
	emitIndent(gen);
	emitClassDeclInner(gen, node);
}

// ===== Method Declaration =====

export function emitMethodDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as MethodDeclData;
	emitIndent(gen);
	if (d.methodIsStatic) { emit(gen, "static "); }
	if (d.methodFlags === "async") { emit(gen, "async "); }
	else if (d.methodFlags === "generator") { emit(gen, "*"); }
	else if (d.methodFlags === "async_generator") { emit(gen, "async *"); }
	emit(gen, d.methodName);
	emit(gen, "(");
	emitJoinedStrings(gen, d.methodParams, ", ");
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.methodBody);
	emitNewline(gen);
}

// ===== Constructor Declaration =====

export function emitConstructorDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as ConstructorDeclData;
	emitIndent(gen);
	emit(gen, "constructor(");
	emitJoinedStrings(gen, d.ctorParams, ", ");
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.ctorBody);
	emitNewline(gen);
}

// ===== Import Declaration =====

export function emitImportDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as ImportDeclData;
	// Skip std/ imports (compiler-provided, not available in JS)
	if (d.importSource.length >= 4) {
		const prefix = sliceStr(d.importSource, 0, 4);
		if (prefix === "std/") return;
	}
	emitIndent(gen);
	if (d.importNames.length === 0) {
		// Side-effect import
		emit(gen, "import \"");
		emit(gen, convertImportPath(d.importSource));
		emit(gen, "\";\n");
		return;
	}
	emit(gen, "import { ");
	for (let i = 0; i < d.importNames.length; i += 1) {
		if (i > 0) emit(gen, ", ");
		emit(gen, d.importNames[i]);
		// Handle aliases
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
	if (inner.kind === NodeKind.TypeAliasDecl) return;
	if (inner.kind === NodeKind.ExternDecl) return;
	emitIndent(gen);
	emit(gen, "export ");
	if (inner.kind === NodeKind.FunctionDecl) {
		emitFunctionDeclInner(gen, inner);
	} else if (inner.kind === NodeKind.VariableDecl) {
		const vd = inner.data as VariableDeclData;
		if (vd.declKind === DeclKind.Const) {
			emit(gen, "const ");
		} else if (vd.declKind === DeclKind.Var) {
			emit(gen, "var ");
		} else {
			emit(gen, "let ");
		}
		emit(gen, vd.declName);
		if (vd.initializer !== null) {
			emit(gen, " = ");
			emitNode(gen, vd.initializer);
		}
		emit(gen, ";\n");
	} else if (inner.kind === NodeKind.EnumDecl) {
		emitEnumDeclInner(gen, inner);
	} else if (inner.kind === NodeKind.ClassDecl) {
		emitClassDeclInner(gen, inner);
	} else {
		emitNode(gen, inner);
	}
}

// ===== Decorated Declaration =====

export function emitDecoratedDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as DecoratedDeclData;
	// Skip decorators, just emit the inner declaration
	emitNode(gen, d.decoratedNode);
}
