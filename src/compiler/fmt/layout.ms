// Doc tree to string: an iterative command-stack printer whose fits() also measures the rest of
// the current line.

import { FormatOptions, TrailingComma } from "./options";
import { Doc, DocKind, docCommaSepList, docText, docGroup, docIndent, docLine, docSoftLine, docHardLine, docIfBreak, docNil, docLineSuffix, docBreakParent, docGroupBreak, docSourceText, docGroupWithId, docIfGroupBreaks, docIndentIfGroupBreaks, docBestFitting, docFill, newGroupId, noGroupId, docWillBreak, docWithoutSoftLines } from "./doc";

enum Mode {
	Flat,
	Break,
}

interface Cmd {
	indent: int32;
	mode: Mode;
	doc: Doc;
	fillAt: int32;
}

function textOf(doc: Doc): string {
	return (doc.data as { text: string }).text;
}

function childrenOf(doc: Doc): Doc[] {
	return (doc.data as { children: Doc[] }).children;
}

function isSoft(doc: Doc): boolean {
	return (doc.data as { isSoft: boolean }).isSoft;
}

function branchesOf(doc: Doc): { broken: Doc, flat: Doc } {
	return doc.data as { broken: Doc, flat: Doc };
}

function variantsOf(doc: Doc): Doc[][] {
	return (doc.data as { variants: Doc[][] }).variants;
}

function pushDocsFrom(stack: Cmd[], docs: Doc[], from: int32, indent: int32, mode: Mode): void {
	for (let j = docs.length - 1; j >= from; j -= 1) {
		stack.push({ indent, mode, doc: docs[j], fillAt: 0 });
	}
}

function pushDocs(stack: Cmd[], docs: Doc[], indent: int32, mode: Mode): void {
	pushDocsFrom(stack, docs, 0, indent, mode);
}

function pushChildren(stack: Cmd[], doc: Doc, indent: int32, mode: Mode): void {
	pushDocs(stack, childrenOf(doc), indent, mode);
}

// The mode each group with an id printed in, shared by printing and measuring.
type GroupModes = HashMap<int32, Mode>;

function recordGroupMode(modes: GroupModes, doc: Doc, mode: Mode): void {
	if (doc.groupId != noGroupId) modes.set(doc.groupId, mode);
}

// A conditional or an indent that names a group takes that group's mode, else the mode it prints in.
function modeOfNamedGroup(modes: GroupModes, doc: Doc, fallback: Mode): Mode {
	if (doc.groupId == noGroupId) return fallback;
	return modes.get(doc.groupId) ?? fallback;
}

function printedModeOfNamedGroup(modes: GroupModes, doc: Doc, current: Mode): Mode {
	if (doc.groupId == noGroupId) return current;
	const mode = modes.get(doc.groupId);
	if (mode === null) throw new Error("internal: a conditional names group " + doc.groupId + " that was never printed before it");
	return mode;
}

// A group holding a BreakParent or HardLine must break, and so must every group around it, a group
// that breaks by itself included; a best fitting doc is a boundary the break does not cross.
function propagateBreaks(doc: Doc): boolean {
	return match (doc.kind) {
		DocKind.BreakParent | DocKind.HardLine => true,
		DocKind.Group | DocKind.Indent | DocKind.LineSuffix | DocKind.IndentIfGroupBreaks | DocKind.Fill => {
			let hasBreak = false;
			for (const child of childrenOf(doc)) {
				if (propagateBreaks(child)) hasBreak = true;
			}
			if (hasBreak && doc.kind == DocKind.Group) doc.shouldBreak = true;
			return doc.kind == DocKind.Group ? doc.shouldBreak : hasBreak;
		},
		DocKind.BestFitting => {
			for (const variant of variantsOf(doc)) {
				for (const child of variant) propagateBreaks(child);
			}
			return false;
		},
		DocKind.IfBreak => {
			const branches = branchesOf(doc);
			propagateBreaks(branches.flat);
			propagateBreaks(branches.broken);
			return false;
		},
		DocKind.Nil | DocKind.Text | DocKind.SourceText | DocKind.Line => false,
	};
}

function endsInSourceText(lineSuffixes: Doc[]): boolean {
	const parts = childrenOf(lineSuffixes[lineSuffixes.length - 1]);
	return parts.length > 0 && parts[parts.length - 1].kind == DocKind.SourceText;
}

function flushSuffixes(lineSuffixes: Doc[]): string {
	let out = "";
	for (const ls of lineSuffixes) {
		for (const part of childrenOf(ls)) {
			if (part.kind == DocKind.Text || part.kind == DocKind.SourceText) out = out + textOf(part);
		}
	}
	lineSuffixes.length = 0;
	return out;
}

function trimTrailingBlanks(text: string, floor: int32): string {
	let end = text.length;
	while (end > floor && (text.charCodeAt(end - 1) == 32 || text.charCodeAt(end - 1) == 9)) {
		end -= 1;
	}
	return end == text.length ? text : text.slice(0, end);
}

const wideRanges: int32[] = [
	0x1100, 0x115f, 0x2e80, 0x303e, 0x3041, 0x33ff, 0x3400, 0x4dbf, 0x4e00, 0x9fff,
	0xa000, 0xa4cf, 0xac00, 0xd7a3, 0xf900, 0xfaff, 0xfe30, 0xfe6f, 0xff00, 0xff60,
	0xffe0, 0xffe6, 0x1f300, 0x1f64f, 0x1f680, 0x1f6ff, 0x1f900, 0x1faff, 0x20000, 0x3fffd,
];

function charWidth(code: int32, tabWidth: int32): int32 {
	if (code == 9) return tabWidth;
	if (code < 32 || (code >= 0x7f && code <= 0x9f)) return 0;
	if ((code >= 0x300 && code <= 0x36f) || (code >= 0xfe00 && code <= 0xfe0f)) return 0;
	for (let i = 0; i < wideRanges.length; i += 2) {
		if (code >= wideRanges[i] && code <= wideRanges[i + 1]) return 2;
	}
	return 1;
}

// Columns `text` occupies when it holds no line break; the wide ranges cover CJK and emoji only.
function displayWidth(text: string, tabWidth: int32): int32 {
	let width = 0;
	let i = 0;
	while (i < text.length) {
		let code = text.charCodeAt(i);
		i += 1;
		if (code >= 0xd800 && code <= 0xdbff && i < text.length) {
			const low = text.charCodeAt(i);
			if (low >= 0xdc00 && low <= 0xdfff) {
				code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
				i += 1;
			}
		}
		width += charWidth(code, tabWidth);
	}
	return width;
}

function firstLineWidth(text: string, tabWidth: int32): int32 {
	const newline = text.indexOf("\n");
	return displayWidth(newline < 0 ? text : text.slice(0, newline), tabWidth);
}

function indentString(levels: int32, options: FormatOptions): string {
	return options.useTabs ? "\t".repeat(levels) : " ".repeat(levels * options.tabWidth);
}

function indentWidth(prefix: string, options: FormatOptions): int32 {
	let w = 0;
	for (let i = 0; i < prefix.byteLength; i += 1) {
		w = w + (prefix.byteAt(i) == "\t".code ? options.tabWidth : 1);
	}
	return w;
}

// Whether `next` fits in `width` columns, then whether the rest of the line (the commands left
// on `rest` up to `restIdx`) still fits behind it, each rest command measured in its own mode.
// `mustBeFlat` refuses a group that breaks by itself and a text holding a line break.
function fits(next: Cmd[], rest: Cmd[], restIdx: int32, width: int32, tabWidth: int32, modes: GroupModes, mustBeFlat: boolean): boolean {
	const stack: Cmd[] = next;
	let remaining = width;
	let restLeft = restIdx;

	while (remaining >= 0) {
		if (stack.length == 0) {
			if (restLeft < 0) return true;
			stack.push(rest[restLeft]);
			restLeft -= 1;
			continue;
		}
		const cmd = stack[stack.length - 1];
		stack.shrink(stack.length - 1);
		const doc = cmd.doc;
		match (doc.kind) {
			DocKind.Nil | DocKind.BreakParent | DocKind.LineSuffix => {},
			DocKind.Text | DocKind.SourceText => {
				const text = textOf(doc);
				remaining = remaining - firstLineWidth(text, tabWidth);
				if (text.indexOf("\n") >= 0) return !mustBeFlat && remaining >= 0;
			},
			DocKind.Group => {
				if (mustBeFlat && doc.shouldBreak) return false;
				const groupMode = doc.shouldBreak ? Mode.Break : cmd.mode;
				recordGroupMode(modes, doc, groupMode);
				pushChildren(stack, doc, cmd.indent, groupMode);
			},
			DocKind.Indent => { pushChildren(stack, doc, cmd.indent + 1, cmd.mode); },
			DocKind.IndentIfGroupBreaks => {
				const broken = modeOfNamedGroup(modes, doc, cmd.mode) == Mode.Break;
				pushChildren(stack, doc, broken ? cmd.indent + 1 : cmd.indent, cmd.mode);
			},
			DocKind.BestFitting => {
				const variants = variantsOf(doc);
				pushDocs(stack, cmd.mode == Mode.Flat ? variants[0] : variants[variants.length - 1], cmd.indent, cmd.mode);
			},
			DocKind.Fill => { pushDocsFrom(stack, childrenOf(doc), cmd.fillAt, cmd.indent, cmd.mode); },
			DocKind.Line => {
				if (cmd.mode == Mode.Break) return true;
				if (!isSoft(doc)) remaining = remaining - 1;
			},
			DocKind.HardLine => { return true; },
			DocKind.IfBreak => {
				const branches = branchesOf(doc);
				stack.push({
					indent: cmd.indent,
					mode: cmd.mode,
					doc: modeOfNamedGroup(modes, doc, cmd.mode) == Mode.Break ? branches.broken : branches.flat,
					fillAt: 0,
				});
			},
		}
	}

	return false;
}

// Whether the first `count` entries of a fill, from `at`, fit flat in `width` columns, the last one
// in `lastMode`, without looking at what follows the fill.
function fillFits(cmd: Cmd, parts: Doc[], at: int32, count: int32, lastMode: Mode, width: int32, tabWidth: int32, modes: GroupModes): boolean {
	const probe: Cmd[] = [];
	for (let k = at + count - 1; k >= at; k -= 1) {
		probe.push({ indent: cmd.indent, mode: k == at + count - 1 ? lastMode : Mode.Flat, doc: parts[k], fillAt: 0 });
	}
	return fits(probe, probe, -1, width, tabWidth, modes, true);
}

export function formatDoc(doc: Doc, options: FormatOptions): string {
	return formatDocAt(doc, options, "");
}

export function formatDocAt(doc: Doc, options: FormatOptions, baseIndent: string): string {
	propagateBreaks(doc);

	let result = "";
	const baseWidth = indentWidth(baseIndent, options);
	let column = baseWidth;
	const lineSuffixes: Doc[] = [];
	const stack: Cmd[] = [{ indent: 0, mode: Mode.Break, doc, fillAt: 0 }];
	const modes: GroupModes = new HashMap<int32, Mode>();
	let measuredFits = false;
	let line = "";
	let textEnd = 0;

	while (stack.length > 0) {
		const cmd = stack[stack.length - 1];
		stack.shrink(stack.length - 1);
		const d = cmd.doc;

		match (d.kind) {
			DocKind.Nil | DocKind.BreakParent => {},
			DocKind.Text | DocKind.SourceText => {
				const text = textOf(d);
				const tailStart = text.lastIndexOf("\n") + 1;
				if (tailStart > 0) {
					measuredFits = false;
					result = result + line + text.slice(0, tailStart);
					line = text.slice(tailStart);
					column = displayWidth(line, options.tabWidth);
					textEnd = line.length;
				} else {
					line = line + text;
					column = column + displayWidth(text, options.tabWidth);
					if (d.kind == DocKind.SourceText) textEnd = line.length;
				}
			},
			DocKind.Group => {
				let childMode = Mode.Break;
				if (!d.shouldBreak) {
					if (cmd.mode == Mode.Flat && measuredFits) {
						childMode = Mode.Flat;
					} else {
						measuredFits = true;
						const flatCmd: Cmd = { indent: cmd.indent, mode: Mode.Flat, doc: d, fillAt: 0 };
						if (fits([flatCmd], stack, stack.length - 1, options.printWidth - column, options.tabWidth, modes, false)) {
							childMode = Mode.Flat;
						}
					}
				}
				recordGroupMode(modes, d, childMode);
				pushChildren(stack, d, cmd.indent, childMode);
			},
			DocKind.Indent => { pushChildren(stack, d, cmd.indent + 1, cmd.mode); },
			DocKind.IndentIfGroupBreaks => {
				const broken = printedModeOfNamedGroup(modes, d, cmd.mode) == Mode.Break;
				pushChildren(stack, d, broken ? cmd.indent + 1 : cmd.indent, cmd.mode);
			},
			DocKind.BestFitting => {
				const variants = variantsOf(d);
				let chosen = variants[variants.length - 1];
				let chosenMode = Mode.Break;
				if (cmd.mode == Mode.Flat && measuredFits) {
					chosen = variants[0];
					chosenMode = Mode.Flat;
				} else {
					measuredFits = true;
					for (let v = 0; v < variants.length - 1; v += 1) {
						const probe: Cmd[] = [];
						pushDocs(probe, variants[v], cmd.indent, Mode.Flat);
						if (fits(probe, stack, stack.length - 1, options.printWidth - column, options.tabWidth, modes, false)) {
							chosen = variants[v];
							chosenMode = Mode.Flat;
							break;
						}
					}
				}
				pushDocs(stack, chosen, cmd.indent, chosenMode);
			},
			DocKind.Fill => {
				const parts = childrenOf(d);
				if (cmd.fillAt < parts.length) {
					if (cmd.mode == Mode.Flat && measuredFits) {
						pushDocsFrom(stack, parts, cmd.fillAt, cmd.indent, Mode.Flat);
					} else {
						measuredFits = true;
						const fillAt = cmd.fillAt;
						const width = options.printWidth - column;
						const item = parts[fillAt];
						const hasSep = fillAt + 1 < parts.length;
						const hasNext = fillAt + 2 < parts.length;
						let itemMode = Mode.Flat;
						let sepMode = Mode.Flat;
						if (!fillFits(cmd, parts, fillAt, 1, Mode.Flat, width, options.tabWidth, modes)) {
							itemMode = Mode.Break;
							sepMode = Mode.Break;
						} else if (hasSep) {
							if (!fillFits(cmd, parts, fillAt, 2, Mode.Flat, width, options.tabWidth, modes)) {
								sepMode = Mode.Break;
								if (!fillFits(cmd, parts, fillAt, 2, Mode.Break, width, options.tabWidth, modes)) itemMode = Mode.Break;
							} else if (hasNext && !fillFits(cmd, parts, fillAt, 3, Mode.Flat, width, options.tabWidth, modes)) {
								sepMode = Mode.Break;
							}
						}
						if (hasNext) stack.push({ indent: cmd.indent, mode: cmd.mode, doc: d, fillAt: fillAt + 2 });
						if (hasSep) stack.push({ indent: cmd.indent, mode: sepMode, doc: parts[fillAt + 1], fillAt: 0 });
						stack.push({ indent: cmd.indent, mode: itemMode, doc: item, fillAt: 0 });
					}
				}
			},
			DocKind.Line | DocKind.HardLine => {
				if (d.kind == DocKind.HardLine || cmd.mode == Mode.Break) {
					measuredFits = false;
					if (lineSuffixes.length > 0) {
						const fromSource = endsInSourceText(lineSuffixes);
						line = line + flushSuffixes(lineSuffixes);
						if (fromSource) textEnd = line.length;
					}
					result = result + trimTrailingBlanks(line, textEnd) + "\n";
					line = baseIndent + indentString(cmd.indent, options);
					textEnd = 0;
					column = baseWidth + cmd.indent * options.tabWidth;
				} else if (!isSoft(d)) {
					line = line + " ";
					column = column + 1;
				}
			},
			DocKind.IfBreak => {
				const branches = branchesOf(d);
				stack.push({
					indent: cmd.indent,
					mode: cmd.mode,
					doc: printedModeOfNamedGroup(modes, d, cmd.mode) == Mode.Break ? branches.broken : branches.flat,
					fillAt: 0,
				});
			},
			DocKind.LineSuffix => { lineSuffixes.push(d); },
		}
	}

	if (lineSuffixes.length > 0) line = line + flushSuffixes(lineSuffixes);
	result = result + line;
	if (result.length > 0 && result.charCodeAt(result.length - 1) != 10) result = result + "\n";
	return result;
}

const narrow: FormatOptions = {
	printWidth: 10,
	tabWidth: 2,
	source: "",
	useTabs: false,
	semi: true,
	singleQuote: false,
	trailingComma: TrailingComma.All,
};

test "layout: a group that fits stays on one line, one that does not breaks" {
	const call = (arg: string): Doc => docGroup([
		docText("f("),
		docIndent([docSoftLine(), docText(arg)]),
		docSoftLine(),
		docText(")"),
	]);
	assert formatDoc(call("a"), narrow) == "f(a)\n";
	assert formatDoc(call("abcdefghij"), narrow) == "f(\n  abcdefghij\n)\n";
}

test "layout: a hard line breaks every enclosing group" {
	const doc = docGroup([docText("a"), docLine(), docGroup([docText("b"), docHardLine(), docText("c")])]);
	assert formatDoc(doc, narrow) == "a\nb\nc\n";
}

test "layout: a line suffix prints at the end of its line" {
	const doc = docGroup([docText("a"), docLineSuffix([docText(" // x")]), docHardLine(), docText("b")]);
	assert formatDoc(doc, narrow) == "a // x\nb\n";
}

test "layout: ifBreak follows the nearest group and tabs indent by level" {
	const body = (): Doc[] => [
		docIndent([docSoftLine(), docText("abcdefghijk"), docIfBreak(docText(","), docNil())]),
		docSoftLine(),
	];
	assert formatDoc(docGroup(body()), narrow) == "\n  abcdefghijk,\n";
	const tabs: FormatOptions = { ...narrow, useTabs: true };
	assert formatDoc(docGroupBreak(body()), tabs) == "\n\tabcdefghijk,\n";
	assert formatDoc(docGroup([docText("x"), docBreakParent()]), narrow) == "x\n";
}

test "layout: pending blanks are dropped before a line break" {
	const doc = docGroupBreak([docText("a +"), docText(" "), docLine(), docText("b")]);
	assert formatDoc(doc, narrow) == "a +\nb\n";
}

test "layout: source text keeps its own trailing blanks at a line break, inline or as a line suffix" {
	const inline = docGroupBreak([docSourceText("// keep "), docText(" "), docHardLine(), docText("b")]);
	assert formatDoc(inline, narrow) == "// keep \nb\n";
	const suffix = docGroupBreak([docText("a;"), docLineSuffix([docText(" "), docSourceText("// tail ")]), docHardLine(), docText("b")]);
	assert formatDoc(suffix, narrow) == "a; // tail \nb\n";
}

test "layout: a printed token's trailing blank is pending, so a line break drops it" {
	const doc = docGroupBreak([docText("a ||"), docText(" b && "), docHardLine(), docText("c")]);
	assert formatDoc(doc, narrow) == "a || b &&\nc\n";
}

test "layout: an indented blank line carries no tab, and a multi-line text keeps its own blanks" {
	const tabs: FormatOptions = { ...narrow, useTabs: true };
	const blank = docGroupBreak([docText("a"), docIndent([docHardLine(), docHardLine(), docText("b")])]);
	assert formatDoc(blank, tabs) == "a\n\n\tb\n";
	const literal = docGroupBreak([docText("x\n  "), docText("  "), docHardLine(), docText("b")]);
	assert formatDoc(literal, narrow) == "x\n  \nb\n";
}

test "layout: a trailing comma added by break mode counts against the last item" {
	const lastItem = (): Doc => docGroup([
		docText("h("),
		docIndent([docSoftLine(), docText("xxxxx")]),
		docSoftLine(),
		docText(")"),
	]);
	const call = (items: Doc[]): Doc => docGroup([
		docText("f("),
		docIndent(docCommaSepList(items, true)),
		docSoftLine(),
		docText(")"),
	]);
	assert formatDoc(call([docText("aaaaaaaaaaaa"), lastItem()]), narrow) == "f(\n  aaaaaaaaaaaa,\n  h(\n    xxxxx\n  ),\n)\n";
	assert formatDoc(call([docText("aaaaaaaaaaaa"), docText("bbbbbbb")]), narrow) == "f(\n  aaaaaaaaaaaa,\n  bbbbbbb,\n)\n";
}

test "layout: a nested conditional in the rest queue is measured too" {
	const doc = docGroupBreak([
		docIndent([docSoftLine(), docGroup([docText("a("), docSoftLine(), docText("bcde)")]), docIfBreak(docGroup([docText(";"), docText(";")]), docNil())]),
		docSoftLine(),
	]);
	assert formatDoc(doc, narrow) == "\n  a(\n  bcde);;\n";
}

test "layout: width counts display columns, a tab as the tab width" {
	const call = (arg: string): Doc => docGroup([
		docText("f("),
		docIndent([docSoftLine(), docText(arg)]),
		docSoftLine(),
		docText(")"),
	]);
	assert formatDoc(call("日日日"), narrow) == "f(日日日)\n";
	assert formatDoc(call("日日日日"), narrow) == "f(\n  日日日日\n)\n";
	assert formatDoc(call("🚀🚀🚀🚀"), narrow) == "f(\n  🚀🚀🚀🚀\n)\n";
	assert formatDoc(call("é\u0301éé"), narrow) == "f(é\u0301éé)\n";
	assert formatDoc(call("\t\t\t\ta"), narrow) == "f(\n  \t\t\t\ta\n)\n";
}

test "layout: a multi-line text fits by its first line and continues the column from its last" {
	const call = (arg: string): Doc => docGroup([
		docText("f("),
		docIndent([docSoftLine(), docText(arg), docText(",")]),
		docSoftLine(),
		docText(")"),
	]);
	assert formatDoc(call("`a\nb`"), narrow) == "f(`a\nb`,)\n";
	assert formatDoc(call("`aaaaaaaaa\nb`"), narrow) == "f(\n  `aaaaaaaaa\nb`,\n)\n";
	const after = docGroupBreak([docText("`a\nb`"), docGroup([docLine(), docText("ccccc")])]);
	assert formatDoc(after, narrow) == "`a\nb` ccccc\n";
}

test "layout: formatDocAt indents continuation lines by the base prefix" {
	const doc = docGroupBreak([docText("a"), docIndent([docHardLine(), docText("b")])]);
	assert formatDocAt(doc, narrow, "\t") == "a\n\t  b\n";
}

const wide: FormatOptions = { ...narrow, printWidth: 80, useTabs: true };

test "layout: a conditional on a group id measures with that group's mode, not the enclosing one" {
	const make = (): Doc => {
		const id = newGroupId();
		return docGroupBreak([
			docGroupWithId([docText("The referenced group breaks."), docHardLine()], id),
			docGroup([
				docText("This group breaks because:"),
				docLine(),
				docIfGroupBreaks(docNil(), docText("This content fits but should not be printed."), id),
				docIfGroupBreaks(docText("It measures with the 'if_group_breaks' variant because the referenced group breaks and that's just way too much text."), docNil(), id),
			]),
		]);
	};
	assert formatDoc(make(), wide) == "The referenced group breaks.\nThis group breaks because:\nIt measures with the 'if_group_breaks' variant because the referenced group breaks and that's just way too much text.\n";
}

test "layout: a conditional reads a group id printed in another branch of the document" {
	const id1 = newGroupId();
	const id2 = newGroupId();
	const doc = docGroupBreak([
		docGroupWithId([docText("Group with id-2")], id2),
		docHardLine(),
		docGroupWithId([docText("Group with id-1 does not fit on the line because it exceeds the line width of 80 characters by")], id1),
		docHardLine(),
		docIfGroupBreaks(docNil(), docText("Group 2 fits"), id2),
		docHardLine(),
		docIfGroupBreaks(docText("Group 1 breaks"), docNil(), id1),
	]);
	assert formatDoc(doc, wide) == "Group with id-2\nGroup with id-1 does not fit on the line because it exceeds the line width of 80 characters by\nGroup 2 fits\nGroup 1 breaks\n";
}

test "layout: a conditional or an indent naming a group that never printed fails loud" {
	const never = newGroupId();
	let conditionalThrew = false;
	try {
		formatDoc(docGroupBreak([docIfGroupBreaks(docText("a"), docNil(), never)]), narrow);
	} catch (e) {
		conditionalThrew = true;
	}
	assert conditionalThrew;
	let indentThrew = false;
	try {
		formatDoc(docGroupBreak([docIndentIfGroupBreaks([docText("a")], never)]), narrow);
	} catch (e) {
		indentThrew = true;
	}
	assert indentThrew;
}

test "layout: indentIfGroupBreaks indents by the named group's mode" {
	const make = (): Doc => {
		const id = newGroupId();
		return docGroupBreak([
			docGroupWithId([docText("(aLongHeaderThatBreaksForSomeReason) =>")], id),
			docIndentIfGroupBreaks([docHardLine(), docText("a => b")], id),
		]);
	};
	const tabs20: FormatOptions = { ...narrow, printWidth: 20, useTabs: true };
	assert formatDoc(make(), tabs20) == "(aLongHeaderThatBreaksForSomeReason) =>\n\ta => b\n";
	assert formatDoc(make(), wide) == "(aLongHeaderThatBreaksForSomeReason) =>\na => b\n";
}

function bestFittingExample(): Doc {
	const one = [
		docText("("),
		docGroup([
			docText("["),
			docIndent([docSoftLine(), docText("1,"), docLine(), docText("2,"), docLine(), docText("3")]),
			docSoftLine(),
			docText("]"),
		]),
		docText(")"),
	];
	const two = [
		docText("("),
		docText("["),
		docIndent([docHardLine(), docText("1, 2, 3")]),
		docHardLine(),
		docText("]"),
		docText(")"),
	];
	const three = [
		docText("("),
		docIndent([
			docHardLine(),
			docText("["),
			docIndent([docHardLine(), docText("1,"), docHardLine(), docText("2,"), docHardLine(), docText("3")]),
			docHardLine(),
			docText("]"),
		]),
		docHardLine(),
		docText(")"),
	];
	return docGroupBreak([docText("aVeryLongIdentifier"), docBestFitting([one, two, three])]);
}

test "layout: best fitting takes the first variant that fits flat up to its first line break, else the last" {
	const at = (width: int32): string => formatDoc(bestFittingExample(), { ...wide, printWidth: width });
	assert at(80) == "aVeryLongIdentifier([1, 2, 3])\n";
	assert at(21) == "aVeryLongIdentifier([\n\t1, 2, 3\n])\n";
	assert at(20) == "aVeryLongIdentifier(\n\t[\n\t\t1,\n\t\t2,\n\t\t3\n\t]\n)\n";
}

test "layout: a variant holding a group that expands by itself fits up to that group's first line" {
	const array = (): Doc => docGroupBreak([
		docText("["),
		docIndent([docSoftLine(), docText("1,"), docLine(), docText("2,"), docLine(), docText("3")]),
		docSoftLine(),
		docText("]"),
	]);
	const doc = docGroupBreak([docBestFitting([
		[docText("expect(a).toMatch("), array(), docText(")")],
		[docText("expect(a).toMatch("), docGroupBreak([docIndent([docSoftLine(), array()]), docSoftLine()]), docText(")")],
	])]);
	assert formatDoc(doc, wide) == "expect(a).toMatch([\n\t1,\n\t2,\n\t3\n])\n";
}

function fillExample(): Doc {
	const bracket = (inner: string, close: string): Doc => docGroup([
		docText("["),
		docIndent([docSoftLine(), docText(inner)]),
		docSoftLine(),
		docText(close),
	]);
	return docFill([
		docText("1,"), docLine(),
		docText("2,"), docLine(),
		docText("3,"), docLine(),
		docText("723493294,"), docLine(),
		bracket("5", "],"), docLine(),
		bracket("123456789", "]"),
	]);
}

test "layout: fill packs items on a line, breaks the separator before an item that does not fit and expands an item too wide" {
	const tabs: FormatOptions = { ...narrow, useTabs: true };
	assert formatDoc(fillExample(), tabs) == "1, 2, 3,\n723493294,\n[5],\n[\n\t123456789\n]\n";
	assert formatDocAt(fillExample(), tabs, "\t") == "1, 2, 3,\n\t723493294,\n\t[5],\n\t[\n\t\t123456789\n\t]\n";
}

test "layout: a conditional on the enclosing group's id prints its comma although a fill item measures flat" {
	const id = newGroupId();
	const last = docGroup([
		docText("["),
		docIndent([docSoftLine(), docText("4")]),
		docSoftLine(),
		docText("]"),
		docIfGroupBreaks(docText(","), docNil(), id),
	]);
	const array = docGroupWithId([
		docText("["),
		docIndent([
			docSoftLine(),
			docFill([docText("1,"), docLine(), docText("234568789,"), docLine(), docText("3456789,"), docLine(), last]),
		]),
		docSoftLine(),
		docText("]"),
	], id);
	const tabs20: FormatOptions = { ...narrow, printWidth: 20, useTabs: true };
	assert formatDoc(array, tabs20) == "[\n\t1, 234568789,\n\t3456789, [4],\n]\n";
}

test "layout: a fill inside a group that fits prints flat, and an id-less conditional follows that group" {
	const item = (text: string): Doc => docGroup([docText(text), docIfBreak(docText(","), docNil())]);
	const doc = docGroup([
		docGroup([
			docText("["),
			docIndent([docSoftLine(), docFill([docText("1,"), docLine(), docText("2,"), docLine(), item("3")])]),
			docSoftLine(),
			docText("]"),
		]),
		docText(";"),
		docLineSuffix([docText(" // trailing")]),
	]);
	assert formatDoc(doc, wide) == "[1, 2, 3]; // trailing\n";
}

test "layout: a fill alternates items and separators and ends with an item" {
	let threw = false;
	try {
		docFill([docText("a"), docLine()]);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "layout: a best fitting doc needs at least two variants" {
	let threw = false;
	try {
		docBestFitting([[docText("a")]]);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "layout: docWillBreak sees a forced break, a broken group, a multi-line text and the flat variant of a best fitting doc" {
	assert docWillBreak(docGroup([docText("a"), docHardLine()]));
	assert docWillBreak(docIndent([docBreakParent()]));
	assert docWillBreak(docGroupBreak([docText("a")]));
	assert docWillBreak(docText("`a\nb`"));
	assert !docWillBreak(docGroup([docText("a"), docLine(), docSoftLine()]));
	assert docWillBreak(docBestFitting([[docHardLine()], [docText("b")]]));
	assert !docWillBreak(docBestFitting([[docText("a")], [docHardLine()]]));
}

test "layout: docWithoutSoftLines drops width-dependent breaks and keeps the forced ones" {
	const list = (): Doc => docGroup([
		docText("("),
		docIndent([docSoftLine(), docText("aaaaaa,"), docLine(), docText("bbbbbb"), docIfBreak(docText(","), docNil())]),
		docSoftLine(),
		docText(")"),
	]);
	assert formatDoc(list(), narrow) == "(\n  aaaaaa,\n  bbbbbb,\n)\n";
	assert formatDoc(docWithoutSoftLines(list()), narrow) == "(aaaaaa, bbbbbb)\n";
	assert docWillBreak(docWithoutSoftLines(docGroup([docText("a"), docHardLine()])));
	assert !docWillBreak(docWithoutSoftLines(list()));
}
