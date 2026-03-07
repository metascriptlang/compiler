// Doc IR — Intermediate Representation for the Pretty Printer
// Based on Philip Wadler's "A Prettier Printer" (2003).

export enum DocKind {
	Nil,        // Empty doc
	Text,       // Literal text
	Group,      // Tries to fit on one line; breaks all internal lines if it fails
	Indent,     // Increments indentation level
	Line,       // Breakpoint: becomes space if group fits, newline if it doesn't
	HardLine,   // Always a newline
	IfBreak,    // Conditional content based on whether parent group broke
	LineSuffix, // Content appended at end of current line (trailing comments)
}

export type DocData =
	| { text: string }                              // Text
	| { children: Doc[] }                           // Group, Indent
	| { isSoft: boolean }                           // Line (softLine vs line)
	| { flat: Doc, broken: Doc };                   // IfBreak

export interface Doc {
	kind: DocKind;
	data: DocData;
}

// ===== Factory Helpers =====

export function docNil(): Doc {
	return { kind: DocKind.Nil, data: {} as DocData };
}

export function docText(text: string): Doc {
	return { kind: DocKind.Text, data: { text } as DocData };
}

export function docGroup(children: Doc[]): Doc {
	return { kind: DocKind.Group, data: { children } as DocData };
}

export function docIndent(children: Doc[]): Doc {
	return { kind: DocKind.Indent, data: { children } as DocData };
}

export function docLine(): Doc {
	return { kind: DocKind.Line, data: { isSoft: false } as DocData };
}

export function docSoftLine(): Doc {
	return { kind: DocKind.Line, data: { isSoft: true } as DocData };
}

export function docHardLine(): Doc {
	return { kind: DocKind.HardLine, data: {} as DocData };
}

export function docIfBreak(flat: Doc, broken: Doc): Doc {
	return { kind: DocKind.IfBreak, data: { flat, broken } as DocData };
}

export function docLineSuffix(children: Doc[]): Doc {
	return { kind: DocKind.LineSuffix, data: { children } as DocData };
}

// Common shorthand: join(docs, docLine())
export function docJoin(docs: Doc[], sep: Doc): Doc {
	const result: Doc[] = [];
	for (let i = 0; i < docs.length; i += 1) {
		if (i > 0) result.push(sep);
		result.push(docs[i]);
	}
	return docGroup(result);
}
