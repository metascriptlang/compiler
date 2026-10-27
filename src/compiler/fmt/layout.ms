// Doc tree to string: an iterative command-stack printer whose fits() also measures the rest of
// the current line.

import { FormatOptions, TrailingComma } from "./options";
import { Doc, DocKind, docCommaSepList, docText, docGroup, docIndent, docLine, docSoftLine, docHardLine, docIfBreak, docNil, docLineSuffix, docBreakParent, docGroupBreak } from "./doc";

enum Mode {
	Flat,
	Break,
}

interface Cmd {
	indent: int32;
	mode: Mode;
	doc: Doc;
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

function pushChildren(stack: Cmd[], doc: Doc, indent: int32, mode: Mode): void {
	const children = childrenOf(doc);
	for (let j = children.length - 1; j >= 0; j -= 1) {
		stack.push({ indent, mode, doc: children[j] });
	}
}

// A group holding a BreakParent or HardLine must break, and so must every group around it.
function propagateBreaks(doc: Doc): boolean {
	return match (doc.kind) {
		DocKind.BreakParent | DocKind.HardLine => true,
		DocKind.Group | DocKind.Indent | DocKind.LineSuffix => {
			let hasBreak = false;
			for (const child of childrenOf(doc)) {
				if (propagateBreaks(child)) hasBreak = true;
			}
			if (hasBreak && doc.kind == DocKind.Group) doc.shouldBreak = true;
			return hasBreak;
		},
		DocKind.IfBreak => {
			const branches = branchesOf(doc);
			propagateBreaks(branches.flat);
			propagateBreaks(branches.broken);
			return false;
		},
		DocKind.Nil | DocKind.Text | DocKind.Line => false,
	};
}

function flushSuffixes(lineSuffixes: Doc[]): string {
	let out = "";
	for (const ls of lineSuffixes) {
		for (const part of childrenOf(ls)) {
			if (part.kind == DocKind.Text) out = out + textOf(part);
		}
	}
	lineSuffixes.length = 0;
	return out;
}

function trimTrailingBlanks(text: string, floor: int32): string {
	let end = text.length;
	while (end > floor && (text[end - 1] == " " || text[end - 1] == "\t")) {
		end -= 1;
	}
	return end == text.length ? text : text.slice(0, end);
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
function fits(next: Cmd, rest: Cmd[], restIdx: int32, width: int32): boolean {
	const stack: Cmd[] = [next];
	let remaining = width;
	let restLeft = restIdx;
	let inRest = false;

	while (remaining >= 0) {
		if (stack.length == 0) {
			if (restLeft < 0) return true;
			stack.push(rest[restLeft]);
			restLeft -= 1;
			inRest = true;
			continue;
		}
		const cmd = stack[stack.length - 1];
		stack.shrink(stack.length - 1);
		const doc = cmd.doc;
		match (doc.kind) {
			DocKind.Nil | DocKind.BreakParent | DocKind.LineSuffix => {},
			DocKind.Text => { remaining = remaining - textOf(doc).length; },
			DocKind.Group => {
				if (doc.shouldBreak && !inRest) return false;
				pushChildren(stack, doc, cmd.indent, doc.shouldBreak ? Mode.Break : cmd.mode);
			},
			DocKind.Indent => { pushChildren(stack, doc, cmd.indent + 1, cmd.mode); },
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
					doc: cmd.mode == Mode.Break ? branches.broken : branches.flat,
				});
			},
		}
	}

	return false;
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
	const stack: Cmd[] = [{ indent: 0, mode: Mode.Break, doc }];
	let literalEnd = 0;

	while (stack.length > 0) {
		const cmd = stack[stack.length - 1];
		stack.shrink(stack.length - 1);
		const d = cmd.doc;

		match (d.kind) {
			DocKind.Nil | DocKind.BreakParent => {},
			DocKind.Text => {
				const text = textOf(d);
				result = result + text;
				column = column + text.length;
				if (text.indexOf("\n") >= 0) literalEnd = result.length;
			},
			DocKind.Group => {
				let childMode = Mode.Break;
				if (!d.shouldBreak) {
					const flatCmd: Cmd = { indent: cmd.indent, mode: Mode.Flat, doc: d };
					if (fits(flatCmd, stack, stack.length - 1, options.printWidth - column)) {
						childMode = Mode.Flat;
					}
				}
				pushChildren(stack, d, cmd.indent, childMode);
			},
			DocKind.Indent => { pushChildren(stack, d, cmd.indent + 1, cmd.mode); },
			DocKind.Line | DocKind.HardLine => {
				if (d.kind == DocKind.HardLine || cmd.mode == Mode.Break) {
					if (lineSuffixes.length > 0) result = result + flushSuffixes(lineSuffixes);
					result = trimTrailingBlanks(result, literalEnd) + "\n" + baseIndent + indentString(cmd.indent, options);
					column = baseWidth + cmd.indent * options.tabWidth;
				} else if (!isSoft(d)) {
					result = result + " ";
					column = column + 1;
				}
			},
			DocKind.IfBreak => {
				const branches = branchesOf(d);
				stack.push({
					indent: cmd.indent,
					mode: cmd.mode,
					doc: cmd.mode == Mode.Break ? branches.broken : branches.flat,
				});
			},
			DocKind.LineSuffix => { lineSuffixes.push(d); },
		}
	}

	if (lineSuffixes.length > 0) result = result + flushSuffixes(lineSuffixes);
	if (result.length > 0 && result[result.length - 1] != "\n") result = result + "\n";
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

test "layout: formatDocAt indents continuation lines by the base prefix" {
	const doc = docGroupBreak([docText("a"), docIndent([docHardLine(), docText("b")])]);
	assert formatDocAt(doc, narrow, "\t") == "a\n\t  b\n";
}
