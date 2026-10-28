// Doc IR for the pretty printer: Wadler's "A Prettier Printer" with break propagation.

export enum DocKind {
	Nil,
	Text,
	SourceText,
	Group,
	Indent,
	Line,
	HardLine,
	IfBreak,
	LineSuffix,
	BreakParent,
	IndentIfGroupBreaks,
	BestFitting,
	Fill,
}

export type DocData =
	| { text: string }
	| { children: Doc[] }
	| { isSoft: boolean }
	| { broken: Doc, flat: Doc }
	| { variants: Doc[][] };

export const noGroupId: int32 = 0;

let lastGroupId: int32 = 0;

export function newGroupId(): int32 {
	lastGroupId += 1;
	return lastGroupId;
}

export class Doc {
	kind: DocKind;
	data: DocData;
	shouldBreak: boolean;
	groupId: int32;
}

function createDoc(kind: DocKind, data: DocData): Doc {
	const d = new Doc();
	d.kind = kind;
	d.data = data;
	d.shouldBreak = false;
	d.groupId = noGroupId;
	return d;
}

export function docNil(): Doc {
	return createDoc(DocKind.Nil, {} as DocData);
}

export function docText(text: string): Doc {
	return createDoc(DocKind.Text, { text } as DocData);
}

// Text taken from the source as written, such as a comment: a line break never trims its blanks.
export function docSourceText(text: string): Doc {
	return createDoc(DocKind.SourceText, { text } as DocData);
}

export function docGroup(children: Doc[]): Doc {
	return createDoc(DocKind.Group, { children } as DocData);
}

export function docGroupWithId(children: Doc[], groupId: int32): Doc {
	const d = createDoc(DocKind.Group, { children } as DocData);
	d.groupId = groupId;
	return d;
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

export function docIfBreak(broken: Doc, flat: Doc): Doc {
	return createDoc(DocKind.IfBreak, { broken, flat } as DocData);
}

// The branch follows the mode of the group `groupId`, which must print before this doc.
export function docIfGroupBreaks(broken: Doc, flat: Doc, groupId: int32): Doc {
	const d = createDoc(DocKind.IfBreak, { broken, flat } as DocData);
	d.groupId = groupId;
	return d;
}

export function docIndentIfGroupBreaks(children: Doc[], groupId: int32): Doc {
	const d = createDoc(DocKind.IndentIfGroupBreaks, { children } as DocData);
	d.groupId = groupId;
	return d;
}

// The first variant that fits flat prints flat; none fitting prints the last, most expanded one.
export function docBestFitting(variants: Doc[][]): Doc {
	if (variants.length < 2) throw new Error("internal: best fitting needs the least and the most expanded variant");
	return createDoc(DocKind.BestFitting, { variants } as DocData);
}

// Items and separators alternate, starting and ending with an item. A separator breaks only when
// the next item does not fit behind it on the line.
export function docFill(parts: Doc[]): Doc {
	if (parts.length % 2 == 0 && parts.length > 0) throw new Error("internal: a fill alternates items and separators and ends with an item");
	return createDoc(DocKind.Fill, { children: parts } as DocData);
}

export function docLineSuffix(children: Doc[]): Doc {
	return createDoc(DocKind.LineSuffix, { children } as DocData);
}

export function docBreakParent(): Doc {
	return createDoc(DocKind.BreakParent, {} as DocData);
}

export function docGroupBreak(children: Doc[]): Doc {
	const d = createDoc(DocKind.Group, { children } as DocData);
	d.shouldBreak = true;
	return d;
}

export function docJoin(docs: Doc[], sep: Doc): Doc {
	const result: Doc[] = [];
	for (let i = 0; i < docs.length; i += 1) {
		if (i > 0) result.push(sep);
		result.push(docs[i]);
	}
	return docGroup(result);
}

// A trailing comma appears only when the list breaks and `trailing` is set.
export function docCommaSepList(items: Doc[], trailing: boolean): Doc[] {
	if (items.length == 0) return [];
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

test "docCommaSepList: trailing comma only when the list breaks" {
	const items = [docText("a"), docText("b")];
	assert docCommaSepList(items, true).length == 5;
	assert docCommaSepList([], true).length == 0;
}
