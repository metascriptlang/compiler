import { Node, NodeKind, NodeFlag } from "../../ast/node";
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

export class Placed {
	leading: SourceComment[] = [];
	dangling: SourceComment[] = [];
	trailing: SourceComment[] = [];
}

export class WhenChain {
	line: int32;
	column: int32;
	endLine: int32;
	endColumn: int32;
	parent: Node;
	placed: Placed = new Placed();

	constructor(first: Token, last: Token, parent: Node) {
		this.line = first.line;
		this.column = first.column;
		this.endLine = last.endLine;
		this.endColumn = last.endColumn;
		this.parent = parent;
	}
}

export class Comments {
	all: SourceComment[] = [];
	byNode: HashMap<Node, Placed> = new HashMap<Node, Placed>();
	chains: WhenChain[] = [];
}

class Span {
	node: Node;
	chain: WhenChain | null = null;
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
		if (child.location.endLine == 0 || child.flags.has(NodeFlag.WhenPicked)) return;
		const inner = buildSpan(child);
		if (inner.start < span.start) span.start = inner.start;
		if (inner.end > span.end) span.end = inner.end;
		span.children.push(inner);
	});
	sortChildren(span);
	return span;
}

function sortChildren(span: Span): void {
	for (let i = 1; i < span.children.length; i += 1) {
		const moved = span.children[i];
		let j = i - 1;
		while (j >= 0 && span.children[j].start > moved.start) {
			span.children[j + 1] = span.children[j];
			j -= 1;
		}
		span.children[j + 1] = moved;
	}
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

function placedOf(comments: Comments, span: Span): Placed {
	if (span.chain != null) return span.chain.placed;
	const node = span.node;
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

function endsOwnLineList(kind: NodeKind): boolean {
	return match (kind) {
		NodeKind.ObjectLiteral | NodeKind.ArrayLiteral | NodeKind.CallExpr | NodeKind.NewExpr
			| NodeKind.ObjectPattern | NodeKind.ArrayPattern | NodeKind.MacroInvocation => true,
		_ => false,
	};
}

function isCall(kind: NodeKind): boolean {
	return kind == NodeKind.CallExpr || kind == NodeKind.NewExpr;
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
	let owner = match (c.position) {
		CommentPosition.EndOfLine => preceding != null ? preceding : following,
		CommentPosition.OwnLine => following != null ? following : preceding,
		CommentPosition.SameLine => preceding != null && (following == null || adjacent)
			? preceding
			: following,
	};
	const afterOpenParen = prev != null && prev.kind == TokenKind.LParen;
	if (following == null && owner != null && owner == preceding
		&& ((c.position == CommentPosition.OwnLine && endsOwnLineList(enclosingNode.kind))
			|| (afterOpenParen && isCall(enclosingNode.kind)))) {
		owner = null;
	}
	if (owner == null) {
		placedOf(comments, enclosing).dangling.push(c);
	} else if (owner == preceding) {
		placedOf(comments, owner).trailing.push(c);
	} else {
		placedOf(comments, owner).leading.push(c);
	}
}

function nextSignificant(tokens: Token[], from: int32): int32 {
	let i = from;
	while (i < tokens.length && tokens[i].kind == TokenKind.Comment) i += 1;
	return i;
}

function matchingClose(tokens: Token[], open: int32, openKind: TokenKind, closeKind: TokenKind): int32 {
	let depth = 0;
	for (let i = open; i < tokens.length; i += 1) {
		const kind = tokens[i].kind;
		if (kind == openKind || (openKind == TokenKind.LBrace && kind == TokenKind.QuoteInterp)) depth += 1;
		else if (kind == closeKind) {
			depth -= 1;
			if (depth == 0) return i;
		}
	}
	return -1;
}

function chainEnd(tokens: Token[], whenAt: int32): int32 {
	let at = whenAt;
	while (true) {
		const paren = nextSignificant(tokens, at + 1);
		if (paren >= tokens.length || tokens[paren].kind != TokenKind.LParen) return -1;
		const closeParen = matchingClose(tokens, paren, TokenKind.LParen, TokenKind.RParen);
		if (closeParen < 0) return -1;
		const brace = nextSignificant(tokens, closeParen + 1);
		if (brace >= tokens.length || tokens[brace].kind != TokenKind.LBrace) return -1;
		let last = matchingClose(tokens, brace, TokenKind.LBrace, TokenKind.RBrace);
		if (last < 0) return -1;
		while (true) {
			const next = nextSignificant(tokens, last + 1);
			if (next >= tokens.length || tokens[next].kind != TokenKind.Else) return last;
			const after = nextSignificant(tokens, next + 1);
			if (after >= tokens.length) return -1;
			if (tokens[after].kind == TokenKind.When) {
				at = after;
				break;
			}
			if (tokens[after].kind != TokenKind.LBrace) return -1;
			const closed = matchingClose(tokens, after, TokenKind.LBrace, TokenKind.RBrace);
			return closed;
		}
	}
	return -1;
}

function findChains(tokens: Token[]): Token[][] {
	const found: Token[][] = [];
	let i = 0;
	while (i < tokens.length) {
		if (tokens[i].kind == TokenKind.When) {
			const last = chainEnd(tokens, i);
			if (last >= 0) {
				found.push([tokens[i], tokens[last]]);
				i = last + 1;
				continue;
			}
		}
		i += 1;
	}
	return found;
}

function insideChain(c: Token, chains: Token[][]): boolean {
	const start = posKey(c.line, c.column);
	for (const chain of chains) {
		if (posKey(chain[0].line, chain[0].column) <= start && start < posKey(chain[1].endLine, chain[1].endColumn)) return true;
	}
	return false;
}

export function decorateComments(program: Node, tokens: Token[]): Result<Comments, string> {
	return decorateFrom(buildSpan(program), program, tokens);
}

function decorateFrom(root: Span, program: Node, tokens: Token[]): Result<Comments, string> {
	const comments = new Comments();
	const found = findChains(tokens);
	for (const pair of found) {
		const chainSpan = new Span(program);
		const chain = new WhenChain(pair[0], pair[1], program);
		chainSpan.chain = chain;
		chainSpan.start = posKey(chain.line, chain.column);
		chainSpan.end = posKey(chain.endLine, chain.endColumn);
		const parent = enclosingSpan(root, chainSpan.start, chainSpan.end);
		chain.parent = parent.node;
		parent.children.push(chainSpan);
		sortChildren(parent);
		comments.chains.push(chain);
	}
	let prev: Token | null = null;
	let run: SourceComment[] = [];
	for (const t of tokens) {
		if (t.kind == TokenKind.Comment) {
			if (!insideChain(t, found)) run.push(new SourceComment(t));
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

export function chainsIn(this comments: Comments, node: Node): WhenChain[] {
	const out: WhenChain[] = [];
	for (const chain of comments.chains) {
		if (chain.parent == node) out.push(chain);
	}
	return out;
}

export function unformattedWithin(this comments: Comments, line: int32, column: int32, endLine: int32, endColumn: int32): SourceComment[] {
	const start = posKey(line, column);
	const end = posKey(endLine, endColumn);
	const out: SourceComment[] = [];
	for (const c of comments.all) {
		if (c.formatted) continue;
		if (posKey(c.line, c.column) >= start && posKey(c.endLine, c.endColumn) <= end) out.push(c);
	}
	return out;
}

export function markFormatted(this comment: SourceComment): void {
	comment.formatted = true;
}

export function assertAllFormatted(this comments: Comments): Result<void, string> {
	return reportUnformatted(comments.all);
}

export function assertNodeFormatted(this comments: Comments, node: Node): Result<void, string> {
	const loc = node.location;
	const missed = comments.unformattedWithin(loc.line, loc.column, loc.endLine, loc.endColumn);
	for (const c of comments.leading(node)) if (!c.formatted) missed.push(c);
	for (const c of comments.trailing(node)) if (!c.formatted) missed.push(c);
	return reportUnformatted(missed);
}

function reportUnformatted(list: SourceComment[]): Result<void, string> {
	const missed: string[] = [];
	for (const c of list) {
		if (!c.formatted) missed.push(`${c.line.toString()}:${c.column.toString()}`);
	}
	if (missed.length == 0) return Result.ok(null);
	const count = missed.length.toString();
	return Result.err(`fmt left ${count} comment(s) unformatted at ${missed.join(", ")}`);
}
