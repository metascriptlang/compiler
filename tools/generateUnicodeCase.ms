import { exists, readFile, writeFile } from "std/fs";
import { argv } from "std/process";
import { sha256 } from "std/crypto";

const MAX_CODE_POINT: int32 = 0x10ffff;
const MAX_EXPANSION: int32 = 3;
const DATA_DIGEST =
	"2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c";
const SPECIAL_DIGEST =
	"efc25faf19de21b92c1194c111c932e03d2a5eaf18194e33f1156e96de4c9588";
const PROPERTY_DIGEST =
	"24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08";

struct Mapping {
	code: int32;
	lower: int32[];
	upper: int32[];
}

struct Pair {
	code: int32;
	target: int32;
}

function hexadecimal(text: string): int32 {
	if (text == "") { throw new Error("empty scalar"); }
	let value: int32 = 0;
	for (let i: int32 = 0; i < text.length; i += 1) {
		const c = text.charCodeAt(i);
		const digit = c >= 48 && c <= 57 ? c - 48 :
			c >= 65 && c <= 70 ? c - 65 + 10 : -1;
		if (digit < 0 || value > (MAX_CODE_POINT - digit) / 16) {
			throw new Error("invalid scalar: " + text);
		}
		value = value * 16 + digit;
	}
	return value;
}

function scalarList(text: string): int32[] {
	const result: int32[] = [];
	for (const word of text.trim().split(" ")) {
		if (word == "") { continue; }
		const code = hexadecimal(word);
		if (code >= 0xd800 && code <= 0xdfff) {
			throw new Error("case mapping contains a surrogate");
		}
		result.push(code);
	}
	if (result.length == 0 || result.length > MAX_EXPANSION) {
		throw new Error("case mapping exceeds pinned bounds");
	}
	return result;
}

function pinnedText(path: string, expected: string): string {
	const read = readFile(path);
	if (!read.ok) { throw new Error(read.error.message); }
	const digest = sha256(read.value);
	if (!digest.ok) { throw new Error(digest.error.message); }
	if (digest.value != expected) {
		throw new Error("case-data cohort mismatch: " + path);
	}
	return read.value;
}

function simpleMappings(text: string): Mapping[] {
	const result: Mapping[] = [];
	for (const raw of text.split("\n")) {
		const line = raw.trim();
		if (line == "" || line.endsWith(";;;")) { continue; }
		const fields = line.split(";");
		if (fields.length != 15) { throw new Error("UnicodeData arity"); }
		if (fields[12] == "" && fields[13] == "") { continue; }
		const code = hexadecimal(fields[0]);
		const lower = fields[13] == "" ? code : hexadecimal(fields[13]);
		const upper = fields[12] == "" ? code : hexadecimal(fields[12]);
		if (result.length > 0 && result[result.length - 1].code >= code) {
			throw new Error("unordered UnicodeData mappings");
		}
		result.push({ code, lower: [lower], upper: [upper] });
	}
	if (result.length == 0) { throw new Error("empty case mappings"); }
	return result;
}

function mappingIndex(rows: Mapping[], code: int32): int32 {
	let low: int32 = 0;
	let high = rows.length as int32;
	while (low < high) {
		const middle = low + (high - low) / 2;
		if (rows[middle].code < code) { low = middle + 1; }
		else { high = middle; }
	}
	if (low < rows.length && rows[low].code == code) { return low; }
	rows.push({ code, lower: [code], upper: [code] });
	for (let i = rows.length as int32 - 1; i > low; i -= 1) {
		rows[i] = rows[i - 1];
	}
	rows[low] = { code, lower: [code], upper: [code] };
	return low;
}

function uncomment(raw: string): string {
	const hash = raw.indexOf("#");
	return (hash < 0 ? raw : raw.slice(0, hash)).trim();
}

function specialMappings(text: string, rows: Mapping[]): void {
	let sigmas: int32 = 0;
	for (const raw of text.split("\n")) {
		const line = uncomment(raw);
		if (line == "") { continue; }
		const fields = line.split(";");
		if (fields.length < 5 || fields.length > 6) {
			throw new Error("SpecialCasing arity");
		}
		const condition = fields[4].trim();
		if (condition != "" && condition != "Final_Sigma") {
			const locale = condition.split(" ")[0];
			if (locale != "lt" && locale != "tr" && locale != "az") {
				throw new Error("unhandled default case condition: " + condition);
			}
			continue;
		}
		const code = hexadecimal(fields[0].trim());
		const lower = scalarList(fields[1]);
		const upper = scalarList(fields[3]);
		if (condition == "Final_Sigma") {
			if (code != 0x3a3 || lower.length != 1 || lower[0] != 0x3c2 ||
				upper.length != 1 || upper[0] != code) {
				throw new Error("unexpected Final_Sigma mapping");
			}
			sigmas += 1;
			continue;
		}
		const at = mappingIndex(rows, code);
		rows[at].lower = lower;
		rows[at].upper = upper;
	}
	if (sigmas != 1) { throw new Error("missing Final_Sigma mapping"); }
}

function propertyRanges(text: string, property: string): int32[] {
	const result: int32[] = [];
	for (const raw of text.split("\n")) {
		if (!raw.contains("; " + property)) { continue; }
		const line = uncomment(raw);
		const fields = line.split(";");
		if (fields.length != 2 || fields[1].trim() != property) { continue; }
		const range = fields[0].trim().split("..");
		if (range.length < 1 || range.length > 2) {
			throw new Error("invalid case-property range");
		}
		const low = hexadecimal(range[0]);
		const high = range.length == 1 ? low : hexadecimal(range[1]);
		if (high < low || (result.length > 0 &&
			low <= result[result.length - 2])) {
			throw new Error("unordered case-property ranges");
		}
		if (result.length > 0 && low == result[result.length - 2] + 1) {
			result[result.length - 2] = high;
		} else {
			for (const value of [low, high, 1]) { result.push(value); }
		}
	}
	if (result.length == 0) { throw new Error("empty case property"); }
	return result;
}

function simpleRanges(rows: Mapping[], uppercase: boolean): int32[] {
	const pairs: Pair[] = [];
	for (const row of rows) {
		const target = uppercase ? row.upper : row.lower;
		if (target.length == 1 && target[0] != row.code) {
			pairs.push({ code: row.code, target: target[0] });
		}
	}
	const result: int32[] = [];
	let at: int32 = 0;
	while (at < pairs.length) {
		const first = pairs[at];
		const delta = first.target - first.code;
		let stride: int32 = 1;
		if (at + 1 < pairs.length &&
			pairs[at + 1].target - pairs[at + 1].code == delta) {
			stride = pairs[at + 1].code - first.code;
		}
		let end = at;
		while (end + 1 < pairs.length &&
			pairs[end + 1].target - pairs[end + 1].code == delta &&
			pairs[end + 1].code - pairs[end].code == stride) {
			end += 1;
		}
		for (const value of [first.code, pairs[end].code, stride, delta]) {
			result.push(value);
		}
		at = end + 1;
	}
	return result;
}

function expansions(rows: Mapping[], uppercase: boolean): int32[] {
	const result: int32[] = [];
	for (const row of rows) {
		const target = uppercase ? row.upper : row.lower;
		if (target.length <= 1) { continue; }
		result.push(row.code);
		result.push(target.length);
		for (let i: int32 = 0; i < MAX_EXPANSION; i += 1) {
			result.push(i < target.length ? target[i] : 0);
		}
	}
	return result;
}

function rowAt(data: int32[], width: int32, code: int32): int32 {
	let low: int32 = 0;
	let high = (data.length as int32) / width;
	while (low < high) {
		const middle = low + (high - low) / 2;
		if (data[middle * width] <= code) { low = middle + 1; }
		else { high = middle; }
	}
	return low == 0 ? -1 : (low - 1) * width;
}

function verifyMappings(
	rows: Mapping[], ranges: int32[], full: int32[], uppercase: boolean,
): void {
	for (const row of rows) {
		const expected = uppercase ? row.upper : row.lower;
		const expanded = rowAt(full, 5, row.code);
		if (expanded >= 0 && full[expanded] == row.code) {
			if (expected.length != full[expanded + 1]) {
				throw new Error("compressed expansion length differs");
			}
			for (let i: int32 = 0; i < expected.length; i += 1) {
				if (full[expanded + 2 + i] != expected[i]) {
					throw new Error("compressed expansion differs");
				}
			}
		} else {
			const at = rowAt(ranges, 4, row.code);
			let code = row.code;
			if (at >= 0 && code <= ranges[at + 1] &&
				(code - ranges[at]) % ranges[at + 2] == 0) {
				code += ranges[at + 3];
			}
			if (expected.length != 1 || expected[0] != code) {
				throw new Error("compressed simple mapping differs");
			}
		}
	}
}

function table(name: string, data: int32[], width: int32): string {
	let text = "export const " + name + ": int32[" + String(data.length) +
		"] = [\n";
	for (let at: int32 = 0; at < data.length; at += width) {
		text += "\t";
		for (let i: int32 = 0; i < width; i += 1) {
			if (i > 0) { text += " "; }
			text += String(data[at + i]) + ",";
		}
		text += "\n";
	}
	return text + "];\n";
}

function run(root: string, output: string): void {
	const simple = pinnedText(root + "/UnicodeData.txt", DATA_DIGEST);
	const special = pinnedText(root + "/SpecialCasing.txt", SPECIAL_DIGEST);
	const properties = pinnedText(root + "/DerivedCoreProperties.txt",
		PROPERTY_DIGEST);
	const rows = simpleMappings(simple);
	specialMappings(special, rows);
	const lower = simpleRanges(rows, false);
	const upper = simpleRanges(rows, true);
	const lowerFull = expansions(rows, false);
	const upperFull = expansions(rows, true);
	verifyMappings(rows, lower, lowerFull, false);
	verifyMappings(rows, upper, upperFull, true);
	const cased = propertyRanges(properties, "Cased");
	const ignorable = propertyRanges(properties, "Case_Ignorable");
	let text = "// Generated by tools/generateUnicodeCase.ms.\n";
	text += "// Unicode-3.0 data; see unicodeData.LICENSE.\n\n";
	text += "export const UNICODE_VERSION = \"17.0.0\";\n\n";
	text += table("LOWER_SIMPLE", lower, 4) + "\n";
	text += table("UPPER_SIMPLE", upper, 4) + "\n";
	text += table("LOWER_FULL", lowerFull, 5) + "\n";
	text += table("UPPER_FULL", upperFull, 5) + "\n";
	text += table("CASED_RANGES", cased, 3) + "\n";
	text += table("CASE_IGNORABLE_RANGES", ignorable, 3);
	if (exists(output)) { throw new Error("output already exists"); }
	const written = writeFile(output, text);
	if (!written.ok) { throw new Error(written.error.message); }
	console.log("Unicode17 mappings=" + String(rows.length) +
		" lower ranges=" + String(lower.length / 4) +
		" upper ranges=" + String(upper.length / 4) +
		" expansions=" + String((lowerFull.length + upperFull.length) / 5));
}

when (!testBuild) {
	if (argv.length != 3) {
		throw new Error("usage: generateUnicodeCase.ms input-directory output");
	}
	run(argv[1], argv[2]);
}
