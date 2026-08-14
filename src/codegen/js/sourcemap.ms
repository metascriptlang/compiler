// Source Map v3 for the JS backend.
//
// Positions are NOT threaded through emission. Statement emitters drop
// `/* line N:C "path" */` markers into the output and this module reads them
// back out of the finished text, so a mapping can only describe code that
// actually shipped.

import { escapeJSString } from "./emit";

const VLQ_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// A run of generated columns that shares one source position.
export interface Segment {
	original: int32;   // column in the .ms source
	generated: int32;  // column in the emitted JS
	nameIdx: int32;    // index into names, -1 when unnamed
}

// One line of emitted JS. `inSource` false = no .ms equivalent (headers, imports).
export interface Mapping {
	inSource: boolean;
	fileIdx: int32;
	line: int32;       // 0-indexed line in the .ms source
	segments: Segment[];
}

export interface SourceInfo {
	mappings: Mapping[];
	names: string[];
	files: string[];
}

export function encodeVLQ(values: int32[]): string {
	const shift: int32 = 5;
	const continueBit: int32 = 32;
	const mask: int32 = 31;
	let result = "";
	for (const val of values) {
		const magnitude: int32 = val < 0 ? -val : val;
		let rest: int32 = magnitude << 1;
		if (val < 0) { rest = rest | 1; }
		let more = true;
		while (more) {
			let masked: int32 = rest & mask;
			rest = rest >> shift;
			if (rest > 0) { masked = masked | continueBit; }
			result = result + VLQ_ALPHABET.slice(masked, masked + 1);
			if (rest === 0) { more = false; }
		}
	}
	return result;
}

function addSegment(info: SourceInfo, original: int32, generated: int32): void {
	const current = info.mappings[info.mappings.length - 1];
	current.segments.push({ original, generated, nameIdx: -1 as int32 });
}

function newSourceLine(info: SourceInfo, file: string, line: int32): void {
	let fileIdx: int32 = -1;
	for (let i: int32 = 0; i < info.files.length; i += 1) {
		if (info.files[i] === file) { fileIdx = i; }
	}
	if (fileIdx < 0) {
		fileIdx = info.files.length as int32;
		info.files.push(file);
	}
	info.mappings.push({ inSource: true, fileIdx, line, segments: [] });
}

function newGeneratedLine(info: SourceInfo): void {
	info.mappings.push({ inSource: false, fileIdx: 0 as int32, line: 0 as int32, segments: [] });
}

interface LineDirective {
	ok: boolean;
	line: int32;
	column: int32;
	path: string;
}

// Byte-indexed on purpose: a source path may hold non-ASCII, and a char-index
// walk would report a column the emitted text does not have.
function noDirective(): LineDirective {
	return { ok: false, line: 0 as int32, column: 0 as int32, path: "" };
}

function parseLineDirective(raw: string): LineDirective {
	const s = raw.trim();
	if (!s.startsWith("/* line ")) return noDirective();
	if (!s.endsWith("\" */")) return noDirective();

	let i: int32 = 8;
	let line: int32 = 0;
	let lineDigits: int32 = 0;
	while (i < s.byteLength && s.byteAt(i) >= "0".code && s.byteAt(i) <= "9".code) {
		line = line * 10 + (s.byteAt(i) - "0".code);
		i += 1;
		lineDigits += 1;
	}
	if (lineDigits === 0) return noDirective();
	if (i >= s.byteLength || s.byteAt(i) !== ":".code) return noDirective();
	i += 1;

	let column: int32 = 0;
	let colDigits: int32 = 0;
	while (i < s.byteLength && s.byteAt(i) >= "0".code && s.byteAt(i) <= "9".code) {
		column = column * 10 + (s.byteAt(i) - "0".code);
		i += 1;
		colDigits += 1;
	}
	if (colDigits === 0) return noDirective();
	if (i + 1 >= s.byteLength || s.byteAt(i) !== " ".code) return noDirective();
	i += 1;
	if (s.byteAt(i) !== "\"".code) return noDirective();
	i += 1;

	const pathEnd: int32 = (s.byteLength - 4) as int32;
	if (pathEnd <= i) return noDirective();
	return { ok: true, line, column, path: s.byteSlice(i, pathEnd) };
}

function leadingWhitespace(s: string): int32 {
	let i: int32 = 0;
	while (i < s.byteLength && (s.byteAt(i) === " ".code || s.byteAt(i) === "\t".code)) {
		i += 1;
	}
	return i;
}

// A directive claims every following line until the next one, so a statement
// spanning several emitted lines keeps pointing at its own source line.
export function parseLineDirectives(source: string): SourceInfo {
	const info: SourceInfo = { mappings: [], names: [], files: [] };
	let currentColumn: int32 = 0;
	let currentLine: int32 = 0;
	let currentFile = "";
	for (const raw of source.split("\n")) {
		const directive = parseLineDirective(raw);
		if (directive.ok) {
			currentColumn = directive.column;
			currentLine = (directive.line - 1) as int32;
			currentFile = directive.path;
			newSourceLine(info, currentFile, currentLine);
			addSegment(info, currentColumn, leadingWhitespace(raw));
		} else if (currentFile !== "") {
			newSourceLine(info, currentFile, currentLine);
			addSegment(info, currentColumn, leadingWhitespace(raw));
		} else {
			newGeneratedLine(info);
		}
	}
	return info;
}

function jsonStringArray(items: string[]): string {
	let out = "";
	for (let i: int32 = 0; i < items.length; i += 1) {
		if (i > 0) { out = out + ","; }
		out = `${out}"${escapeJSString(items[i])}"`;
	}
	return out;
}

// Every field is a delta against the previous segment; the generated column is
// the one exception, resetting per line.
export function toSourceMapJson(info: SourceInfo, file: string): string {
	let prevFile: int32 = 0;
	let prevLine: int32 = 0;
	let prevSourceColumn: int32 = 0;
	let mappings = "";
	for (const mapping of info.mappings) {
		if (mapping.inSource) {
			let prevGeneratedColumn: int32 = 0;
			let first = true;
			for (const segment of mapping.segments) {
				if (!first) { mappings = mappings + ","; }
				first = false;
				const values: int32[] = [
					(segment.generated - prevGeneratedColumn) as int32,
					(mapping.fileIdx - prevFile) as int32,
					(mapping.line - prevLine) as int32,
					(segment.original - prevSourceColumn) as int32,
				];
				prevGeneratedColumn = segment.generated;
				prevSourceColumn = segment.original;
				prevFile = mapping.fileIdx;
				prevLine = mapping.line;
				mappings = mappings + encodeVLQ(values);
			}
		}
		mappings = mappings + ";";
	}
	return `{"version":3,"file":"${escapeJSString(file)}","sources":[${jsonStringArray(info.files)}],"names":[],"mappings":"${mappings}"}`;
}

export function genSourceMap(source: string, outFile: string): string {
	return toSourceMapJson(parseLineDirectives(source), outFile);
}

// ===== Tests =====

test "VLQ encodes the sign in the low bit" {
	assert encodeVLQ([0]) === "A";
	assert encodeVLQ([1]) === "C";
	assert encodeVLQ([-1]) === "D";
	assert encodeVLQ([2]) === "E";
	assert encodeVLQ([-2]) === "F";
}

test "VLQ continues past five bits" {
	assert encodeVLQ([16]) === "gB";
	assert encodeVLQ([123]) === "2H";
	assert encodeVLQ([-123]) === "3H";
}

test "VLQ concatenates a segment without separators" {
	assert encodeVLQ([0, 1, 2, 3]) === "ACEG";
	assert encodeVLQ([0, 0, 0, 0]) === "AAAA";
}

test "line directive parses line, column and path" {
	const d = parseLineDirective("  /* line 12:4 \"/a/b.ms\" */");
	assert d.ok;
	assert d.line === 12;
	assert d.column === 4;
	assert d.path === "/a/b.ms";
}

test "line directive rejects anything else" {
	assert !parseLineDirective("const x = 1;").ok;
	assert !parseLineDirective("/* line  \"/a.ms\" */").ok;
	assert !parseLineDirective("/* line 3 \"/a.ms\" */").ok;
	assert !parseLineDirective("// line 3:1 \"/a.ms\"").ok;
}

test "lines before the first directive are unmapped" {
	const info = parseLineDirectives("import x;\n/* line 3:0 \"/a.ms\" */\nconst y = 1;\n");
	assert info.mappings.length === 4;
	assert !info.mappings[0].inSource;
	assert info.mappings[1].inSource;
	assert info.mappings[1].line === 2;
	assert info.files.length === 1;
	assert info.files[0] === "/a.ms";
}

test "a directive claims the lines that follow it" {
	const info = parseLineDirectives("/* line 5:2 \"/a.ms\" */\n  const y = 1;\n  const z = 2;\n");
	assert info.mappings[1].inSource;
	assert info.mappings[1].line === 4;
	assert info.mappings[2].inSource;
	assert info.mappings[2].line === 4;
	assert info.mappings[1].segments[0].generated === 2;
	assert info.mappings[1].segments[0].original === 2;
}

test "map json carries version, source list and mappings" {
	const json = genSourceMap("/* line 1:0 \"/a.ms\" */\nconst y = 1;\n", "out.js");
	assert json.startsWith("{\"version\":3,");
	assert json.includes("\"file\":\"out.js\"");
	assert json.includes("\"sources\":[\"/a.ms\"]");
	assert json.includes("\"mappings\":\"");
}

test "unmapped-only input still emits one semicolon per line" {
	const json = genSourceMap("a\nb\n", "out.js");
	assert json.includes("\"mappings\":\";;;\"");
	assert json.includes("\"sources\":[]");
}
