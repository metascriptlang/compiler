// LSP Handlers — per-line format lint shared by diagnostics and code actions.

// A CRLF terminator drops its "\r"; a trailing newline leaves a final empty line.
export function splitLines(s: string): string[] {
	const lines: string[] = [];
	let start = 0;
	for (let i = 0; i < s.byteLength; i = i + 1) {
		if (s[i] == "\n") {
			const end = i > start && s[i - 1] == "\r" ? i - 1 : i;
			lines.push(s.slice(start, end));
			start = i + 1;
		}
	}
	if (start <= s.byteLength) {
		lines.push(s.slice(start, s.byteLength));
	}
	return lines;
}

// Uses the "tabs for indentation, spaces for alignment" model (EditorConfig/Go convention):
//   - Tabs-mode: tabs first, then optional trailing spaces for alignment -> valid.
//     Only flag when a space appears *before* a tab (interleaved).
//   - Spaces-mode: any tab in leading whitespace -> wrong.
export interface LineIndent {
	indentEnd: int32;
	hasSpace: boolean;
	hasTab: boolean;
	isMixed: boolean;
	trailStart: int32;
}

export function detectLineIndent(line: string): LineIndent {
	let indentEnd = 0;
	let hasSpace = false;
	let hasTab = false;
	let isMixed = false;
	let seenSpace = false;
	while (indentEnd < line.length) {
		if (line[indentEnd] == " ") { hasSpace = true; seenSpace = true; }
		else if (line[indentEnd] == "\t") {
			hasTab = true;
			if (seenSpace) { isMixed = true; }
		}
		else { break; }
		indentEnd = indentEnd + 1;
	}
	let trailStart = line.length;
	while (trailStart > 0 && (line[trailStart - 1] == " " || line[trailStart - 1] == "\t")) {
		trailStart = trailStart - 1;
	}
	return { indentEnd, hasSpace, hasTab, isMixed, trailStart };
}

export enum IndentFault {
	Mixed,
	UseTabs,
	UseSpaces,
}

// The one rule for "this line's indentation is wrong", for the diagnostic and the quick fix alike.
// A block comment continuation line ( * text) is exempt: spaces before * are alignment.
export function indentFault(line: string, info: LineIndent, useTabs: boolean): IndentFault | null {
	if (info.indentEnd == 0 || info.indentEnd >= line.length) return null;
	if (line.byteAt(info.indentEnd) == "*".code) return null;
	if (info.isMixed) return IndentFault.Mixed;
	if (useTabs && info.hasSpace && !info.hasTab) return IndentFault.UseTabs;
	if (!useTabs && info.hasTab && !info.hasSpace) return IndentFault.UseSpaces;
	return null;
}

test "LF line content preserves spaces and trailing blank lines" {
	const lines = splitLines("é😀   \n日\n\n");
	assert lines.length == 4;
	assert lines[0] == "é😀   ";
	assert lines[1] == "日";
	assert lines[2] == "";
	assert lines[3] == "";
}

test "CRLF line content excludes terminators but preserves spaces and blank lines" {
	const lines = splitLines("é😀   \r\n日\r\n\r\n");
	assert lines.length == 4;
	assert lines[0] == "é😀   ";
	assert lines[1] == "日";
	assert lines[2] == "";
	assert lines[3] == "";
}

function faultOf(line: string, useTabs: boolean): IndentFault | null {
	return indentFault(line, detectLineIndent(line), useTabs);
}

test "indent fault follows the tabs-for-indent, spaces-for-alignment model" {
	assert faultOf("\t\tx", true) == null;
	assert faultOf("\t  x", true) == null;
	assert faultOf("  x", true) == IndentFault.UseTabs;
	assert faultOf("\t x", true) == null;
	assert faultOf(" \tx", true) == IndentFault.Mixed;
	assert faultOf("\tx", false) == IndentFault.UseSpaces;
	assert faultOf("  x", false) == null;
	assert faultOf("  * note", true) == null;
	assert faultOf("x", true) == null;
	assert faultOf("   ", true) == null;
}
