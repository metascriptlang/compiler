// Doc IR for the pretty printer: Wadler's "A Prettier Printer" with break propagation.

export enum DocKind {
	Nil,
	Text,
	Group,
	Indent,
	Line,
	HardLine,
	IfBreak,
	LineSuffix,
	BreakParent,
}

export type DocData =
	| { text: string }
	| { children: Doc[] }
	| { isSoft: boolean }
	| { broken: Doc, flat: Doc };

export class Doc {
	kind: DocKind;
	data: DocData;
	shouldBreak: boolean;
}

function createDoc(kind: DocKind, data: DocData): Doc {
	const d = new Doc();
	d.kind = kind;
	d.data = data;
	d.shouldBreak = false;
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

export function docIfBreak(broken: Doc, flat: Doc): Doc {
	return createDoc(DocKind.IfBreak, { broken, flat } as DocData);
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
