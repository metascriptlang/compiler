// Doc IR — Intermediate Representation for the Pretty Printer
// Based on Philip Wadler's "A Prettier Printer" (2003).

export enum DocKind {
	Nil,         // Empty doc
	Text,        // Literal text
	Group,       // Tries to fit on one line; breaks all internal lines if it fails
	Indent,      // Increments indentation level
	Line,        // Breakpoint: becomes space if group fits, newline if it doesn't
	HardLine,    // Always a newline
	IfBreak,     // Conditional content based on whether parent group broke
	LineSuffix,  // Content appended at end of current line (trailing comments)
	BreakParent, // Forces enclosing group to break (Prettier/Biome parity)
	Fill,        // Pack as many items per line as possible (partial wrapping)
}

export type DocData =
	| { text: string }                              // Text
	| { children: Doc[] }                           // Group, Indent, LineSuffix
	| { isSoft: boolean }                           // Line (softLine vs line)
	| { broken: Doc, flat: Doc };                    // IfBreak

export class Doc {
	kind: DocKind;
	data: DocData;
	shouldBreak: boolean; // When true, group always breaks (Prettier: group({ shouldBreak }))
	groupId: number;      // Group ID for cross-group IfBreak references (0 = no ID)
}

// ===== Factory Helpers =====

let _nextGroupId = 1;

function createDoc(kind: DocKind, data: DocData): Doc {
	const d = new Doc();
	d.kind = kind;
	d.data = data;
	d.shouldBreak = false;
	d.groupId = 0;
	return d;
}

// Allocate a unique group ID for cross-group IfBreak references.
export function allocGroupId(): number {
	const id = _nextGroupId;
	_nextGroupId = _nextGroupId + 1;
	return id;
}

// Create a named group (can be referenced by IfBreak via groupId).
export function docGroupWithId(children: Doc[], id: number): Doc {
	const d = createDoc(DocKind.Group, { children } as DocData);
	d.groupId = id;
	return d;
}

export function docNil(): Doc {
	return createDoc(DocKind.Nil, {} as DocData);
}

export function docText(text: string): Doc {
	return createDoc(DocKind.Text, { text } as DocData);
}

export function docGroup(children: Doc[]): Doc {
	return createDoc(DocKind.Group, { children } as DocData);
}

export function docIndent(children: Doc[]): Doc {
	return createDoc(DocKind.Indent, { children } as DocData);
}

export function docLine(): Doc {
	return createDoc(DocKind.Line, { isSoft: false } as DocData);
}

export function docSoftLine(): Doc {
	return createDoc(DocKind.Line, { isSoft: true } as DocData);
}

export function docHardLine(): Doc {
	return createDoc(DocKind.HardLine, {} as DocData);
}

// Prettier convention: first arg is what to show when broken, second when flat.
export function docIfBreak(broken: Doc, flat: Doc): Doc {
	return createDoc(DocKind.IfBreak, { broken, flat } as DocData);
}

// IfBreak that checks a specific group's break status (not just nearest parent).
export function docIfBreakGroup(broken: Doc, flat: Doc, gId: number): Doc {
	const d = createDoc(DocKind.IfBreak, { broken, flat } as DocData);
	d.groupId = gId;
	return d;
}

export function docLineSuffix(children: Doc[]): Doc {
	return createDoc(DocKind.LineSuffix, { children } as DocData);
}

// Force enclosing group to break. Propagated upward by propagateBreaks().
export function docBreakParent(): Doc {
	return createDoc(DocKind.BreakParent, {} as DocData);
}

// Group that always breaks (skip fitsOnOneLine). Shorthand for group + shouldBreak.
export function docGroupBreak(children: Doc[]): Doc {
	const d = createDoc(DocKind.Group, { children } as DocData);
	d.shouldBreak = true;
	return d;
}

// Common shorthand: join docs with separator. Returns a flat list in a group.
// Note: the wrapping group inherits break behavior from propagateBreaks.
export function docJoin(docs: Doc[], sep: Doc): Doc {
	const result: Doc[] = [];
	for (let i = 0; i < docs.length; i += 1) {
		if (i > 0) result.push(sep);
		result.push(docs[i]);
	}
	return docGroup(result);
}

// Fill: pack items with separator, wrapping when a line is full.
// Items and separators alternate: [item, sep, item, sep, item].
// Unlike Group, each pair is measured independently for partial wrapping.
export function docFill(parts: Doc[]): Doc {
	return createDoc(DocKind.Fill, { children: parts } as DocData);
}

// Join without wrapping group — items inherit parent's break mode directly.
export function docJoinFlat(docs: Doc[], sep: Doc): Doc[] {
	const result: Doc[] = [];
	for (let i = 0; i < docs.length; i += 1) {
		if (i > 0) result.push(sep);
		result.push(docs[i]);
	}
	return result;
}

// Build a comma-separated list for params/args/elements.
// Each item gets a comma attached; last item gets trailing comma via ifBreak
// when `trailing` is true. Items separated by Line (inherits parent break mode).
// Returns Doc[] suitable for wrapping in docIndent.
export function docCommaSepList(items: Doc[], trailing: boolean): Doc[] {
	if (items.length === 0) return [];
	const parts: Doc[] = [docSoftLine()];
	for (let i = 0; i < items.length; i += 1) {
		if (i > 0) {
			parts.push(docLine());
		}
		if (i < items.length - 1) {
			parts.push(docGroup([items[i], docText(",")]));
		} else {
			parts.push(items[i]);
			if (trailing) {
				parts.push(docIfBreak(docText(","), docNil()));
			}
		}
	}
	return parts;
}
