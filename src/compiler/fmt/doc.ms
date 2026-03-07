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

export class Doc {
	kind: DocKind;
	data: DocData;
}

// ===== Factory Helpers =====

function createDoc(kind: DocKind, data: DocData): Doc {
	const d = new Doc();
	d.kind = kind;
	d.data = data;
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

export function docIfBreak(flat: Doc, broken: Doc): Doc {
	return createDoc(DocKind.IfBreak, { flat, broken } as DocData);
}

export function docLineSuffix(children: Doc[]): Doc {
	return createDoc(DocKind.LineSuffix, { children } as DocData);
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
