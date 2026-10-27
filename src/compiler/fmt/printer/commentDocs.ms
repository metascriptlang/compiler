import { Node, SourceLocation } from "../../../ast/node";
import { Comments, SourceComment, CommentKind, leading, trailing, dangling, unformattedWithin, markFormatted } from "../comments";
import { Doc, docText, docGroup, docIndent, docLine, docHardLine, docLineSuffix, docBreakParent, docJoin } from "../doc";
import { blankLineBefore } from "./literals";

let placed: Comments = new Comments();

export function useComments(comments: Comments): void {
	placed = comments;
}

export function commentsOfRun(): Comments {
	return placed;
}

function unformatted(list: SourceComment[]): SourceComment[] {
	const out: SourceComment[] = [];
	for (const c of list) {
		if (!c.formatted) out.push(c);
	}
	return out;
}

function emptyLine(): Doc[] {
	return [docHardLine(), docHardLine()];
}

export function leadingDocs(list: SourceComment[]): Doc[] {
	const out: Doc[] = [];
	for (const c of list) {
		out.push(docText(c.text));
		c.markFormatted();
		if (c.kind == CommentKind.Line) {
			if (c.linesAfter <= 1) out.push(docHardLine());
			else for (const d of emptyLine()) out.push(d);
		} else if (c.linesAfter == 0) {
			out.push(docText(" "));
		} else if (c.linesAfter == 1) {
			out.push(c.linesBefore == 0 ? docLine() : docHardLine());
		} else {
			for (const d of emptyLine()) out.push(d);
		}
	}
	return out;
}

export function trailingDocs(list: SourceComment[]): Doc[] {
	const out: Doc[] = [];
	let ownLine = false;
	let previous: SourceComment | null = null;
	for (const c of list) {
		if (c.linesBefore > 0) ownLine = true;
		if (ownLine) {
			if (c.linesBefore == 0) out.push(previous != null && previous.kind == CommentKind.Line ? docHardLine() : docText(" "));
			else if (c.linesBefore == 1) out.push(docHardLine());
			else for (const d of emptyLine()) out.push(d);
			out.push(docText(c.text));
			out.push(docBreakParent());
		} else if (c.kind == CommentKind.Line) {
			out.push(docLineSuffix([docText(" " + c.text)]));
			out.push(docBreakParent());
		} else {
			out.push(docText(" " + c.text));
		}
		c.markFormatted();
		previous = c;
	}
	return out;
}

export function commentLeading(node: Node): Doc[] {
	return leadingDocs(unformatted(placed.leading(node)));
}

export function commentTrailing(node: Node): Doc[] {
	return trailingDocs(unformatted(placed.trailing(node)));
}

export function takeOwnLineTrailing(node: Node): SourceComment[] {
	const out: SourceComment[] = [];
	for (const c of placed.trailing(node)) {
		if (!c.formatted && c.linesBefore > 0) out.push(c);
	}
	for (const c of out) c.markFormatted();
	return out;
}

export function commentLeadingBefore(node: Node, key: SourceLocation): Doc[] {
	const ahead: SourceComment[] = [];
	for (const c of placed.leading(node)) {
		if (!c.formatted && (c.line < key.line || (c.line == key.line && c.column < key.column))) ahead.push(c);
	}
	return leadingDocs(ahead);
}

export function hasCommentsOutside(node: Node): boolean {
	return unformatted(placed.leading(node)).length > 0 || unformatted(placed.trailing(node)).length > 0;
}

export function withComments(node: Node, doc: Doc): Doc {
	const before = commentLeading(node);
	const after = commentTrailing(node);
	if (before.length == 0 && after.length == 0) return doc;
	const parts: Doc[] = [];
	for (const d of before) parts.push(d);
	parts.push(doc);
	for (const d of after) parts.push(d);
	return docGroup(parts);
}

export function danglingLines(list: SourceComment[]): Doc[] {
	const out: Doc[] = [];
	for (const c of list) {
		out.push(docText(c.text));
		c.markFormatted();
	}
	return out;
}

export function danglingOf(node: Node): SourceComment[] {
	return unformatted(placed.dangling(node));
}

export function danglingBlock(list: SourceComment[]): Doc {
	return docJoin(danglingLines(list), docHardLine());
}

export function commentsWithin(from: SourceLocation, to: SourceLocation): SourceComment[] {
	return placed.unformattedWithin(from.line, from.column, to.line, to.column);
}

export function markWithin(from: SourceLocation, to: SourceLocation): void {
	for (const c of commentsWithin(from, to)) c.markFormatted();
}

export function startLineOf(node: Node): int32 {
	const lead = placed.leading(node);
	return lead.length > 0 ? lead[0].line : node.location.line;
}

export function joinKeepingBlankLines(docs: Doc[], starts: int32[]): Doc[] {
	const out: Doc[] = [];
	for (let i = 0; i < docs.length; i += 1) {
		if (i > 0) {
			out.push(docHardLine());
			if (blankLineBefore(starts[i])) out.push(docHardLine());
		}
		out.push(docs[i]);
	}
	return out;
}

export function interleave(items: Doc[], lines: int32[], starts: int32[], inner: SourceComment[]): Doc[] {
	const out: Doc[] = [];
	const outStarts: int32[] = [];
	let at = 0;
	for (let i = 0; i < items.length; i += 1) {
		while (at < inner.length && inner[at].line < lines[i]) {
			out.push(docText(inner[at].text));
			outStarts.push(inner[at].line);
			inner[at].markFormatted();
			at += 1;
		}
		const next = i + 1 < items.length ? lines[i + 1] : 999999;
		const entry: Doc[] = [items[i]];
		while (at < inner.length && inner[at].line == lines[i] && inner[at].line < next) {
			entry.push(docLineSuffix([docText(" " + inner[at].text)]));
			inner[at].markFormatted();
			at += 1;
		}
		out.push(docGroup(entry));
		outStarts.push(starts[i]);
	}
	while (at < inner.length) {
		out.push(docText(inner[at].text));
		outStarts.push(inner[at].line);
		inner[at].markFormatted();
		at += 1;
	}
	return joinKeepingBlankLines(out, outStarts);
}

export function boxed(open: string, body: Doc[], close: string): Doc {
	return docGroup([docText(open), docIndent([docHardLine(), ...body]), docHardLine(), docText(close)]);
}
