// JavaScript Codegen — Emit Helpers
//
// JSGenerator context, low-level emit functions.
// emitNode delegates to registered callback (set by jsgen.ms) to break circular imports.

import { Node, NodeKind, BlockStmtData } from "../../ast/node";
import { sliceStr } from "../../utils/string";
import { check } from "std/testing";

// ===== JS Generator =====

export interface JSGenerator {
	buf: string[];
	indentLevel: number;
}

export function createJSGenerator(): JSGenerator {
	return { buf: [], indentLevel: 0 };
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

export function emit(gen: JSGenerator, text: string): void {
	gen.buf.push(text);
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
	for (let i = 0; i < d.statements.length; i += 1) {
		emitNode(gen, d.statements[i]);
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

export function finalize(gen: JSGenerator): string {
	let result = "";
	for (let i = 0; i < gen.buf.length; i += 1) {
		result = result + gen.buf[i];
	}
	return result;
}

// ===== String Escaping =====

export function escapeJSString(s: string): string {
	let result = "";
	for (let i = 0; i < s.length; i += 1) {
		const ch = sliceStr(s, i, i + 1);
		if (ch === "\\") { result = result + "\\\\"; }
		else if (ch === "\"") { result = result + "\\\""; }
		else if (ch === "\n") { result = result + "\\n"; }
		else if (ch === "\r") { result = result + "\\r"; }
		else if (ch === "\t") { result = result + "\\t"; }
		else if (ch === "\0") { result = result + "\\0"; }
		else { result = result + ch; }
	}
	return result;
}

// ===== Import Path Conversion =====

export function convertImportPath(path: string): string {
	if (path.length >= 3) {
		const suffix = sliceStr(path, path.length - 3, path.length);
		if (suffix === ".ms") {
			return sliceStr(path, 0, path.length - 3) + ".js";
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
	check(finalize(gen) === "hello world");
}

test "indentation" {
	const gen = createJSGenerator();
	gen.indentLevel = 2;
	emitIndent(gen);
	emit(gen, "x");
	check(finalize(gen) === "    x");
}

test "emitLine" {
	const gen = createJSGenerator();
	emitLine(gen, "const x = 1;");
	check(finalize(gen) === "const x = 1;\n");
}

test "escapeJSString basics" {
	check(escapeJSString("hello") === "hello");
	check(escapeJSString("a\\b") === "a\\\\b");
}

test "convertImportPath" {
	check(convertImportPath("./module.ms") === "./module.js");
	check(convertImportPath("./module") === "./module");
	check(convertImportPath("std/testing") === "std/testing");
}
