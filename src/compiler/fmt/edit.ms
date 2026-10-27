import { Node, NodeKind, ProgramData, BlockStmtData } from "../../ast/node";
import { Token } from "../../lexer/token";
import { forEachChild } from "../../ast/visitor";
import { FormatOptions } from "./options";
import { formatNodeAt } from "./printer/index";
import { LineIndex, lineOffset } from "../../utils/sourceLines";
import { ByteEdit, diffTextEdits } from "./textEdit";

export { lineOffset } from "../../utils/sourceLines";

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

export interface StatementRun {
	first: Node;
	last: Node;
	root: Node;
}

function byteOffset(lines: LineIndex, pos: FmtPos): int32 {
	return lines.lineStart(pos.line) + pos.column - 1;
}

export function formatRunEdits(run: StatementRun, source: string, options: FormatOptions): Result<ByteEdit[], string> {
	options.source = source;
	const lines = LineIndex.build(source);
	const firstSpan = try statementSpan(run.first);
	const lastSpan = try statementSpan(run.last);
	let runStart = lineOffset(source, firstSpan.start.line);
	if (source.byteSlice(runStart, byteOffset(lines, firstSpan.start)).trim() != "") runStart = byteOffset(lines, firstSpan.start);
	const runEnd = byteOffset(lines, lastSpan.end);

	let rootStart = 0;
	let rootEnd = source.byteLength;
	let indent = "";
	if (run.root.kind != NodeKind.Program) {
		const span = try statementSpan(run.root);
		rootStart = byteOffset(lines, span.start);
		rootEnd = byteOffset(lines, span.end);
		indent = leadingWhitespace(source, span.start.line);
	}
	const printed = try formatNodeAt(run.root, options, indent);
	const newText = run.root.kind != NodeKind.Program && printed.endsWith("\n") ? printed.byteSlice(0, printed.byteLength - 1) : printed;

	const kept: ByteEdit[] = [];
	for (const edit of diffTextEdits(source.byteSlice(rootStart, rootEnd), newText)) {
		const start = rootStart + edit.start;
		const end = rootStart + edit.end;
		const inside = start == end ? start >= runStart && start <= runEnd : start < runEnd && end > runStart;
		if (inside) kept.push({ start, end, newText: edit.newText });
	}
	return Result.ok(kept);
}

export function applyEdit(source: string, edit: FmtEdit): string {
	const lines = LineIndex.build(source);
	const from = lines.lineStart(edit.start.line) + edit.start.column - 1;
	const to = lines.lineStart(edit.end.line) + edit.end.column - 1;
	return source.byteSlice(0, from) + edit.newText + source.byteSlice(to, source.byteLength);
}

function isStatementList(node: Node): boolean {
	return node.kind == NodeKind.Program || node.kind == NodeKind.BlockStmt;
}

function statementsOf(node: Node): Node[] {
	return node.kind == NodeKind.Program ? (node.data as ProgramData).programStmts : (node.data as BlockStmtData).statements;
}

function touches(stmt: Node, from: FmtPos, to: FmtPos): Result<boolean, string> {
	const loc = stmt.location;
	if (loc.endLine == 0) return Result.err(`statement at ${loc.line}:${loc.column} has no recorded end`);
	const start: FmtPos = { line: loc.line, column: loc.column };
	const end: FmtPos = { line: loc.endLine, column: loc.endColumn };
	if (before(from, to)) return Result.ok(before(from, end) && before(start, to));
	return Result.ok(!before(from, start) && !before(end, from));
}

function contains(stmt: Node, from: FmtPos, to: FmtPos): boolean {
	const loc = stmt.location;
	return !before(from, { line: loc.line, column: loc.column }) && !before(to, { line: loc.line, column: loc.column }) && !before({ line: loc.endLine, column: loc.endColumn }, to);
}

function runIn(node: Node, from: FmtPos, to: FmtPos): Result<StatementRun | null, string> {
	if (isStatementList(node)) {
		const touched: Node[] = [];
		for (const s of statementsOf(node)) {
			if (try touches(s, from, to)) touched.push(s);
		}
		if (touched.length == 0) return Result.ok(null);
		const last = touched[touched.length - 1];
		const own: StatementRun = { first: touched[0], last, root: touched.length == 1 ? last : node };
		if (touched.length != 1 || !contains(touched[0], from, to)) return Result.ok(own);
		const inner = try runInChildren(touched[0], from, to);
		return Result.ok(inner != null ? inner : own);
	}
	return runInChildren(node, from, to);
}

function runInChildren(node: Node, from: FmtPos, to: FmtPos): Result<StatementRun | null, string> {
	const runs: StatementRun[] = [];
	let failure = "";
	forEachChild(node, (child: Node): void => {
		const run = runIn(child, from, to);
		if (!run.ok) failure = run.error;
		else if (run.value != null) runs.push(run.value);
	});
	if (failure != "") return Result.err(failure);
	return Result.ok(runs.length == 1 ? runs[0] : null);
}

export function rangeStatements(program: Node, from: FmtPos, to: FmtPos): Result<StatementRun | null, string> {
	return runIn(program, from, to);
}
