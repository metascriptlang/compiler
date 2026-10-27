import { Node } from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { Token, TokenKind } from "../../lexer/token";

export enum CommentKind {
	Line,
	InlineBlock,
	Block,
}

export enum CommentPosition {
	EndOfLine,
	OwnLine,
	SameLine,
}

export class SourceComment {
	text: string;
	kind: CommentKind;
	line: int32;
	column: int32;
	endLine: int32;
	endColumn: int32;
	position: CommentPosition = CommentPosition.SameLine;
	linesBefore: int32 = 0;
	linesAfter: int32 = 0;
	formatted: boolean = false;

	constructor(token: Token) {
		this.text = token.value;
		this.kind = token.value.startsWith("//")
			? CommentKind.Line
			: token.value.contains("\n") ? CommentKind.Block : CommentKind.InlineBlock;
		this.line = token.line;
		this.column = token.column;
		this.endLine = token.endLine;
		this.endColumn = token.endColumn;
	}
}

class Placed {
	leading: SourceComment[] = [];
	dangling: SourceComment[] = [];
	trailing: SourceComment[] = [];
}

export class Comments {
	all: SourceComment[] = [];
	byNode: HashMap<Node, Placed> = new HashMap<Node, Placed>();
}

class Span {
	node: Node;
	start: int64;
	end: int64;
	children: Span[] = [];

	constructor(node: Node) {
		this.node = node;
		this.start = posKey(node.location.line, node.location.column);
		this.end = posKey(node.location.endLine, node.location.endColumn);
	}
}

function posKey(line: int32, column: int32): int64 {
	return (line as int64) * 1048576 + (column as int64);
}

function buildSpan(node: Node): Span {
	const span = new Span(node);
	forEachChild(node, (child: Node): void => {
		if (child.location.endLine == 0) return;
		const inner = buildSpan(child);
		if (inner.start < span.start) span.start = inner.start;
		if (inner.end > span.end) span.end = inner.end;
		span.children.push(inner);
	});
	for (let i = 1; i < span.children.length; i += 1) {
		const moved = span.children[i];
		let j = i - 1;
		while (j >= 0 && span.children[j].start > moved.start) {
			span.children[j + 1] = span.children[j];
			j -= 1;
		}
		span.children[j + 1] = moved;
	}
	return span;
}

function enclosingSpan(root: Span, start: int64, end: int64): Span {
	let current = root;
	let descended = true;
	while (descended) {
		descended = false;
		for (const child of current.children) {
			if (child.start <= start && end <= child.end) {
				current = child;
				descended = true;
				break;
			}
		}
	}
	return current;
}

function placedOf(comments: Comments, node: Node): Placed {
	const existing = comments.byNode.get(node);
	if (existing != null) return existing;
	const created = new Placed();
	comments.byNode.set(node, created);
	return created;
}

function decorateRun(run: SourceComment[], prev: Token | null, next: Token): void {
	let lastEndLine = prev != null ? prev.endLine : 1;
	let firstNewline = run.length;
	for (let i = 0; i < run.length; i += 1) {
		const c = run[i];
		c.linesBefore = c.line - lastEndLine;
		if (c.linesBefore > 0 && firstNewline == run.length) firstNewline = i;
		c.position = firstNewline <= i ? CommentPosition.OwnLine : CommentPosition.SameLine;
		lastEndLine = c.endLine;
	}
	const linesAfterLast = Math.max(next.line - lastEndLine, 0) as int32;
	for (let i = 0; i < run.length; i += 1) {
		run[i].linesAfter = i + 1 < run.length ? run[i + 1].linesBefore : linesAfterLast;
		if (i < firstNewline && (firstNewline < run.length || linesAfterLast > 0)) {
			run[i].position = CommentPosition.EndOfLine;
		}
	}
}

function placeComment(comments: Comments, root: Span, c: SourceComment, prev: Token | null): void {
	const start = posKey(c.line, c.column);
	const end = posKey(c.endLine, c.endColumn);
	const enclosing = enclosingSpan(root, start, end);
	let preceding: Span | null = null;
	let following: Span | null = null;
	for (const child of enclosing.children) {
		if (child.end <= start) preceding = child;
		else if (child.start >= end && following == null) following = child;
	}
	const adjacent = preceding != null && prev != null
		&& preceding.end == posKey(prev.endLine, prev.endColumn);
	const enclosingNode = enclosing.node;
	const owner = match (c.position) {
		CommentPosition.EndOfLine => preceding != null ? preceding : following,
		CommentPosition.OwnLine => following != null ? following : preceding,
		CommentPosition.SameLine => preceding != null && (following == null || adjacent)
			? preceding
			: following,
	};
	if (owner == null) {
		placedOf(comments, enclosingNode).dangling.push(c);
	} else if (owner == preceding) {
		placedOf(comments, owner.node).trailing.push(c);
	} else {
		placedOf(comments, owner.node).leading.push(c);
	}
}

export function decorateComments(program: Node, tokens: Token[]): Result<Comments, string> {
	const root = buildSpan(program);
	const comments = new Comments();
	let prev: Token | null = null;
	let run: SourceComment[] = [];
	for (const t of tokens) {
		if (t.kind == TokenKind.Comment) {
			run.push(new SourceComment(t));
			continue;
		}
		if (run.length > 0) {
			decorateRun(run, prev, t);
			for (const c of run) {
				comments.all.push(c);
				placeComment(comments, root, c, prev);
			}
			run = [];
		}
		if (t.kind != TokenKind.Eof) prev = t;
	}
	if (run.length > 0) return Result.err("token stream ends in a comment without an end marker");
	return Result.ok(comments);
}

const noComments: SourceComment[] = [];

export function leading(this comments: Comments, node: Node): SourceComment[] {
	const placed = comments.byNode.get(node);
	return placed != null ? placed.leading : noComments;
}

export function dangling(this comments: Comments, node: Node): SourceComment[] {
	const placed = comments.byNode.get(node);
	return placed != null ? placed.dangling : noComments;
}

export function trailing(this comments: Comments, node: Node): SourceComment[] {
	const placed = comments.byNode.get(node);
	return placed != null ? placed.trailing : noComments;
}

export function markFormatted(this comment: SourceComment): void {
	comment.formatted = true;
}

export function assertAllFormatted(this comments: Comments): Result<void, string> {
	const missed: string[] = [];
	for (const c of comments.all) {
		if (!c.formatted) missed.push(`${c.line.toString()}:${c.column.toString()}`);
	}
	if (missed.length == 0) return Result.ok(null);
	const count = missed.length.toString();
	return Result.err(`fmt left ${count} comment(s) unformatted at ${missed.join(", ")}`);
}
