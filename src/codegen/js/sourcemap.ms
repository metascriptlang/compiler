// Source Map v3 for the JS backend.
//
// Mappings are recorded while the JS is written, one per emitted node, so the
// resolution is per token rather than per line and the emitted file carries no
// trace of the map. Composition (module → bundle) shifts generated lines and
// re-indexes sources, which is what keeps a prepended header honest.

import { relative } from "std/fs/path";

// Reading the .ms text is the driver's job; this module stays free of I/O.
export type SourceReader = (path: string) => string;

const VLQ_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// One position in the emitted JS that has a .ms origin. Each carries its own
// file and line: a single emitted line routinely mixes origins once calls are
// inlined onto it.
export interface Segment {
	generated: int32;  // UTF-16 column in the emitted JS
	fileIdx: int32;
	line: int32;       // 0-indexed line in the .ms source
	original: int32;   // 0-indexed column in the .ms source
	nameIdx: int32;    // index into names, -1 when unnamed
}

// One line of emitted JS. No segments = no .ms equivalent (headers, imports).
export interface Mapping {
	segments: Segment[];
}

export interface SourceInfo {
	mappings: Mapping[];
	names: string[];
	files: string[];
}

export function createSourceInfo(): SourceInfo {
	return { mappings: [], names: [], files: [] };
}

export function internFile(info: SourceInfo, file: string): int32 {
	for (let i: int32 = 0; i < info.files.length; i += 1) {
		if (info.files[i] === file) return i;
	}
	info.files.push(file);
	return (info.files.length - 1) as int32;
}

export function internName(info: SourceInfo, name: string): int32 {
	for (let i: int32 = 0; i < info.names.length; i += 1) {
		if (info.names[i] === name) return i;
	}
	info.names.push(name);
	return (info.names.length - 1) as int32;
}

function ensureLine(info: SourceInfo, genLine: int32): void {
	while (info.mappings.length <= genLine) {
		info.mappings.push({ segments: [] });
	}
}

// A nested node marks the same generated position as the node that contains it
// and is the more precise answer, so the later record replaces the earlier one.
export function recordSegment(info: SourceInfo, genLine: int32, genCol: int32,
		fileIdx: int32, line: int32, original: int32, nameIdx: int32): void {
	ensureLine(info, genLine);
	const segs = info.mappings[genLine].segments;
	if (segs.length > 0 && segs[segs.length - 1].generated === genCol) {
		segs[segs.length - 1] = { generated: genCol, fileIdx, line, original, nameIdx };
		return;
	}
	segs.push({ generated: genCol, fileIdx, line, original, nameIdx });
}

// Everything the module emitted now starts `count` lines further down.
export function shiftLines(info: SourceInfo, count: int32): void {
	if (count <= 0) return;
	const blanks: Mapping[] = [];
	for (let i: int32 = 0; i < count; i += 1) { blanks.push({ segments: [] }); }
	for (const m of info.mappings) { blanks.push(m); }
	info.mappings = blanks;
}

// Concatenate `src` onto `dst` at generated line `atLine`, re-indexing its
// sources and names into the destination's tables.
export function appendInfo(dst: SourceInfo, src: SourceInfo, atLine: int32): void {
	const fileMap: int32[] = [];
	for (const f of src.files) { fileMap.push(internFile(dst, f)); }
	const nameMap: int32[] = [];
	for (const n of src.names) { nameMap.push(internName(dst, n)); }
	for (let i: int32 = 0; i < src.mappings.length; i += 1) {
		const line = (atLine + i) as int32;
		ensureLine(dst, line);
		for (const s of src.mappings[i].segments) {
			dst.mappings[line].segments.push({
				generated: s.generated,
				fileIdx: fileMap[s.fileIdx],
				line: s.line,
				original: s.original,
				nameIdx: s.nameIdx < 0 ? -1 as int32 : nameMap[s.nameIdx],
			});
		}
	}
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

// JSON has no \x escape and forbids raw control bytes, so escapeJSString cannot
// be reused here: it would emit \x00 for NUL and pass \f and \v through raw.
// Bytes are copied in runs so multi-byte UTF-8 stays intact; WTF-8 lone
// surrogates become \uXXXX.
export function jsonEscape(s: string): string {
	let result = "";
	let runStart: int32 = 0;
	let i: int32 = 0;
	while (i < s.byteLength) {
		const b = s.byteAt(i);
		if (b === "\\".code || b === "\"".code || b < 32) {
			if (runStart < i) result = result + s.byteSlice(runStart, i);
			result = result + match (b) {
				"\\".code => "\\\\",
				"\"".code => "\\\"",
				8 => "\\b",
				9 => "\\t",
				10 => "\\n",
				12 => "\\f",
				13 => "\\r",
				_ => "\\u" + b.toString(16).padStart(4, "0"),
			};
			i += 1;
			runStart = i;
		} else if (b === 237 && i + 2 < s.byteLength
				&& s.byteAt(i + 1) >= 160 && s.byteAt(i + 1) <= 191) {
			if (runStart < i) result = result + s.byteSlice(runStart, i);
			const cu = 53248 + (s.byteAt(i + 1) - 128) * 64 + (s.byteAt(i + 2) - 128);
			result = result + "\\u" + cu.toString(16).padStart(4, "0");
			i += 3;
			runStart = i;
		} else {
			i += 1;
		}
	}
	if (runStart < i) result = result + s.byteSlice(runStart, i);
	return result;
}

function jsonStringArray(items: string[]): string {
	let out = "";
	for (let i: int32 = 0; i < items.length; i += 1) {
		if (i > 0) { out = out + ","; }
		out = `${out}"${jsonEscape(items[i])}"`;
	}
	return out;
}

// Sources are written relative to the directory holding the .map, and their
// text is inlined, so a debugger resolves the .ms without a second fetch and
// without depending on the build machine's layout. A source that cannot be
// read is `null`, which the spec allows per entry.
function sourcesJson(info: SourceInfo, mapDir: string, read: SourceReader): string {
	let sources = "";
	let contents = "";
	for (let i: int32 = 0; i < info.files.length; i += 1) {
		if (i > 0) { sources = sources + ","; contents = contents + ","; }
		const abs = info.files[i];
		const rel = mapDir === "" ? abs : relative(mapDir, abs);
		sources = `${sources}"${jsonEscape(rel === "" ? abs : rel)}"`;
		const text = read(abs);
		contents = text === "" ? contents + "null" : `${contents}"${jsonEscape(text)}"`;
	}
	return `"sources":[${sources}],"sourcesContent":[${contents}]`;
}

// Every field is a delta against the previous segment; the generated column is
// the one exception, resetting per line.
export function toSourceMapJson(info: SourceInfo, file: string, mapDir: string, read: SourceReader): string {
	let prevFile: int32 = 0;
	let prevLine: int32 = 0;
	let prevSourceColumn: int32 = 0;
	let prevName: int32 = 0;
	let mappings = "";
	for (const mapping of info.mappings) {
		let prevGeneratedColumn: int32 = 0;
		let first = true;
		for (const segment of mapping.segments) {
			if (!first) { mappings = mappings + ","; }
			first = false;
			const values: int32[] = [
				(segment.generated - prevGeneratedColumn) as int32,
				(segment.fileIdx - prevFile) as int32,
				(segment.line - prevLine) as int32,
				(segment.original - prevSourceColumn) as int32,
			];
			if (segment.nameIdx >= 0) {
				values.push((segment.nameIdx - prevName) as int32);
				prevName = segment.nameIdx;
			}
			prevGeneratedColumn = segment.generated;
			prevSourceColumn = segment.original;
			prevFile = segment.fileIdx;
			prevLine = segment.line;
			mappings = mappings + encodeVLQ(values);
		}
		mappings = mappings + ";";
	}
	return `{"version":3,"file":"${jsonEscape(file)}",${sourcesJson(info, mapDir, read)},"names":[${jsonStringArray(info.names)}],"mappings":"${mappings}"}`;
}

// ===== Tests =====

function noSource(path: string): string { return ""; }

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

function oneSegment(file: string, genLine: int32, genCol: int32, line: int32, col: int32): SourceInfo {
	const info = createSourceInfo();
	recordSegment(info, genLine, genCol, internFile(info, file), line, col, -1 as int32);
	return info;
}

test "a file is interned once" {
	const info = createSourceInfo();
	assert internFile(info, "/a.ms") === 0;
	assert internFile(info, "/b.ms") === 1;
	assert internFile(info, "/a.ms") === 0;
	assert info.files.length === 2;
}

test "recording fills the generated lines it skipped over" {
	const info = oneSegment("/a.ms", 3 as int32, 2 as int32, 4 as int32, 1 as int32);
	assert info.mappings.length === 4;
	assert info.mappings[0].segments.length === 0;
	assert info.mappings[3].segments.length === 1;
	assert info.mappings[3].segments[0].generated === 2;
	assert info.mappings[3].segments[0].line === 4;
}

test "the innermost record wins at one generated column" {
	const info = createSourceInfo();
	const f = internFile(info, "/a.ms");
	recordSegment(info, 0 as int32, 5 as int32, f, 10 as int32, 0 as int32, -1 as int32);
	recordSegment(info, 0 as int32, 5 as int32, f, 12 as int32, 4 as int32, -1 as int32);
	assert info.mappings[0].segments.length === 1;
	assert info.mappings[0].segments[0].line === 12;
	assert info.mappings[0].segments[0].original === 4;
}

test "shifting moves every mapping down" {
	const info = oneSegment("/a.ms", 1 as int32, 0 as int32, 7 as int32, 0 as int32);
	shiftLines(info, 3 as int32);
	assert info.mappings.length === 5;
	assert info.mappings[1].segments.length === 0;
	assert info.mappings[4].segments[0].line === 7;
}

test "appending re-indexes sources into the destination" {
	const dst = oneSegment("/a.ms", 0 as int32, 0 as int32, 1 as int32, 0 as int32);
	const src = oneSegment("/b.ms", 0 as int32, 0 as int32, 9 as int32, 2 as int32);
	appendInfo(dst, src, 2 as int32);
	assert dst.files.length === 2;
	assert dst.mappings.length === 3;
	assert dst.mappings[2].segments[0].fileIdx === 1;
	assert dst.mappings[2].segments[0].line === 9;
}

test "map json carries version, source list and mappings" {
	const json = toSourceMapJson(oneSegment("/a.ms", 0 as int32, 0 as int32, 0 as int32, 0 as int32), "out.js", "", noSource);
	assert json.startsWith("{\"version\":3,");
	assert json.includes("\"file\":\"out.js\"");
	assert json.includes("\"sources\":[\"/a.ms\"]");
	assert json.includes("\"mappings\":\"AAAA;\"");
}

test "a line with no segments is one bare semicolon" {
	const json = toSourceMapJson(oneSegment("/a.ms", 2 as int32, 0 as int32, 0 as int32, 0 as int32), "out.js", "", noSource);
	assert json.includes("\"mappings\":\";;AAAA;\"");
}

test "an empty map still parses" {
	const json = toSourceMapJson(createSourceInfo(), "out.js", "", noSource);
	assert json.includes("\"mappings\":\"\"");
	assert json.includes("\"sources\":[]");
	assert json.includes("\"sourcesContent\":[]");
}

test "sources are relative to the map directory" {
	const json = toSourceMapJson(oneSegment("/p/src/a.ms", 0 as int32, 0 as int32, 0 as int32, 0 as int32), "out.js", "/p/out/js", noSource);
	assert json.includes("\"sources\":[\"../../src/a.ms\"]");
}

test "an unreadable source is null, a readable one is inlined" {
	const info = oneSegment("/a.ms", 0 as int32, 0 as int32, 0 as int32, 0 as int32);
	assert toSourceMapJson(info, "out.js", "", noSource).includes("\"sourcesContent\":[null]");
	const withText = toSourceMapJson(info, "out.js", "", (p: string): string => "let a = 1;");
	assert withText.includes("\"sourcesContent\":[\"let a = 1;\"]");
}

test "a named segment encodes its fifth field" {
	const info = createSourceInfo();
	recordSegment(info, 0 as int32, 0 as int32, internFile(info, "/a.ms"), 0 as int32, 0 as int32, internName(info, "alpha"));
	const json = toSourceMapJson(info, "out.js", "", noSource);
	assert json.includes("\"names\":[\"alpha\"]");
	assert json.includes("\"mappings\":\"AAAAA;\"");
}

test "json escape covers what escapeJSString cannot" {
	assert jsonEscape("a\"b\\c") === "a\\\"b\\\\c";
	assert jsonEscape("a\nb\tc") === "a\\nb\\tc";
	assert jsonEscape(fromCodePoint(12)) === "\\f";
	assert jsonEscape(fromCodePoint(11)) === "\\u000b";
	assert jsonEscape(fromCodePoint(0)) === "\\u0000";
	assert jsonEscape(fromCodePoint(1)) === "\\u0001";
}

test "json escape keeps astral runs intact" {
	const astral = fromCodePoint(128512);
	assert jsonEscape(astral) === astral;
	assert jsonEscape(fromCodePoint(55296)) === "\\" + "ud800";
}
