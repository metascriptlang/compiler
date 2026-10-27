import { Node, NodeKind, ProgramData, BlockStmtData, ClassDeclData } from "../../ast/node";
import { Token } from "../../lexer/token";
import { forEachChild } from "../../ast/visitor";
import { FormatOptions } from "./options";
import { formatNodeAt } from "./printer/index";
import { LineIndex, lineOffset } from "../../utils/sourceLines";

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
	stmts: Node[];
	keepsBlankLines: boolean;
}

export function formatStatementsEdit(run: StatementRun, source: string, options: FormatOptions): Result<FmtEdit, string> {
	const stmts = run.stmts;
	options.source = source;
	const first = try statementSpan(stmts[0]);
	const indent = leadingWhitespace(source, first.start.line);
	let text = "";
	let end = first.end;
	for (let i = 0; i < stmts.length; i += 1) {
		const span = try statementSpan(stmts[i]);
		if (i > 0) text += try gapBetween(source, end, span.start, indent, run.keepsBlankLines);
		const printed = try formatNodeAt(stmts[i], options, indent);
		text += printed.endsWith("\n") ? printed.byteSlice(0, printed.byteLength - 1) : printed;
		end = span.end;
	}
	return Result.ok({ start: first.start, end, newText: text });
}

function gapBetween(source: string, from: FmtPos, to: FmtPos, indent: string, keepsBlankLines: boolean): Result<string, string> {
	const lines = LineIndex.build(source);
	const gap = source.byteSlice(lines.lineStart(from.line) + from.column - 1, lines.lineStart(to.line) + to.column - 1);
	if (gap.trim() != "") return Result.err(`range formatting: unattached text "${gap.trim()}" between statements at ${from.line}:${from.column} and ${to.line}:${to.column}`);
	if (to.line == from.line) return Result.ok(gap);
	return Result.ok(keepsBlankLines && to.line - from.line > 1 ? "\n\n" + indent : "\n" + indent);
}

export function applyEdit(source: string, edit: FmtEdit): string {
	const lines = LineIndex.build(source);
	const from = lines.lineStart(edit.start.line) + edit.start.column - 1;
	const to = lines.lineStart(edit.end.line) + edit.end.column - 1;
	return source.byteSlice(0, from) + edit.newText + source.byteSlice(to, source.byteLength);
}

function isStatementList(node: Node): boolean {
	return node.kind == NodeKind.Program || node.kind == NodeKind.BlockStmt || node.kind == NodeKind.ClassDecl;
}

function statementsOf(node: Node): Node[] {
	if (node.kind == NodeKind.Program) return (node.data as ProgramData).programStmts;
	if (node.kind == NodeKind.ClassDecl) return (node.data as ClassDeclData).classBody;
	return (node.data as BlockStmtData).statements;
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
		const own: StatementRun = { stmts: touched, keepsBlankLines: node.kind == NodeKind.Program };
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
