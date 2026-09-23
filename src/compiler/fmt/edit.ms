import { Node, NodeKind, ProgramData, BlockStmtData } from "../../ast/node";
import { Token } from "../../lexer/token";
import { forEachChild } from "../../ast/visitor";
import { FormatOptions } from "./options";
import { formatNodeAt } from "./printer/index";

export interface FmtPos {
	line: int32;
	column: int32;
}

export interface FmtEdit {
	start: FmtPos;
	end: FmtPos;
	newText: string;
}

function before(a: FmtPos, b: FmtPos): boolean {
	return a.line < b.line || (a.line == b.line && a.column < b.column);
}

function commentEnd(c: Token): FmtPos {
	let line = c.line;
	let column = c.column;
	for (let i = 0; i < c.value.byteLength; i += 1) {
		if (c.value.byteAt(i) == "\n".code) {
			line += 1;
			column = 1;
		} else {
			column += 1;
		}
	}
	return { line, column };
}

export function lineOffset(source: string, line: int32): int32 {
	let current = 1;
	let pos = 0;
	while (pos < source.byteLength && current < line) {
		if (source.byteAt(pos) == "\n".code) current += 1;
		pos += 1;
	}
	return pos;
}

function leadingWhitespace(source: string, line: int32): string {
	const start = lineOffset(source, line);
	let end = start;
	while (end < source.byteLength && (source.byteAt(end) == " ".code || source.byteAt(end) == "\t".code)) {
		end += 1;
	}
	return source.byteSlice(start, end);
}

export function statementSpan(stmt: Node): Result<FmtEdit, string> {
	const loc = stmt.location;
	if (loc.endLine == 0) return Result.err(`statement at ${loc.line}:${loc.column} has no recorded end`);
	let start: FmtPos = { line: loc.line, column: loc.column };
	let end: FmtPos = { line: loc.endLine, column: loc.endColumn };
	for (const c of stmt.comments) {
		const cs: FmtPos = { line: c.line, column: c.column };
		const ce = commentEnd(c);
		if (before(cs, start)) start = cs;
		if (before(end, ce)) end = ce;
	}
	return Result.ok({ start, end, newText: "" });
}

export function formatStatementEdit(stmt: Node, source: string, options: FormatOptions): Result<FmtEdit, string> {
	const span = try statementSpan(stmt);
	options.source = source;
	const printed = try formatNodeAt(stmt, options, leadingWhitespace(source, span.start.line));
	const newText = printed.endsWith("\n") ? printed.byteSlice(0, printed.byteLength - 1) : printed;
	return Result.ok({ start: span.start, end: span.end, newText });
}

export function applyEdit(source: string, edit: FmtEdit): string {
	const from = lineOffset(source, edit.start.line) + edit.start.column - 1;
	const to = lineOffset(source, edit.end.line) + edit.end.column - 1;
	return source.byteSlice(0, from) + edit.newText + source.byteSlice(to, source.byteLength);
}

function containsRange(stmt: Node, from: FmtPos, to: FmtPos): boolean {
	const loc = stmt.location;
	if (loc.endLine == 0) return false;
	const start: FmtPos = { line: loc.line, column: loc.column };
	const end: FmtPos = { line: loc.endLine, column: loc.endColumn };
	return !before(from, start) && !before(end, to);
}

function collectContaining(node: Node, from: FmtPos, to: FmtPos, found: Node[]): void {
	if (node.kind == NodeKind.Program) {
		for (const s of (node.data as ProgramData).programStmts) {
			if (containsRange(s, from, to)) found.push(s);
		}
	} else if (node.kind == NodeKind.BlockStmt) {
		for (const s of (node.data as BlockStmtData).statements) {
			if (containsRange(s, from, to)) found.push(s);
		}
	}
	forEachChild(node, (child: Node): void => {
		collectContaining(child, from, to, found);
	});
}

export function innermostStatement(program: Node, from: FmtPos, to: FmtPos): Node | null {
	const found: Node[] = [];
	collectContaining(program, from, to, found);
	if (found.length == 0) return null;
	return found[found.length - 1];
}
