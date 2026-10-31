import { argv } from "std/process";
import { writeStdout } from "std/io";
import { sha256 } from "std/crypto";
import { readUtf8File } from "./textFile";

const DATA_SHA256 =
	"ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183";
const MAX_SCALAR: int32 = 0x10ffff;

struct FoldTables {
	codes: int32[];
	offsets: int32[];
	values: int32[];
}

function hexadecimal(text: string): int32 {
	if (text == "") { throw new Error("empty casefold scalar"); }
	let code: int32 = 0;
	for (let i: int32 = 0; i < text.length; i += 1) {
		const c = text.charCodeAt(i);
		const digit = c >= 48 && c <= 57 ? c - 48 :
			(c >= 65 && c <= 70 ? c - 65 + 10 : -1);
		if (digit < 0 || code > (MAX_SCALAR - digit) / 16) {
			throw new Error("invalid casefold scalar: " + text);
		}
		code = code * 16 + digit;
	}
	if (code >= 0xd800 && code <= 0xdfff) {
		throw new Error("casefold data contains a surrogate");
	}
	return code;
}

function mappings(text: string): FoldTables {
	const codes: int32[] = [];
	const offsets: int32[] = [0];
	const values: int32[] = [];
	for (const raw of text.split("\n")) {
		const hash = raw.indexOf("#");
		const line = (hash < 0 ? raw : raw.slice(0, hash)).trim();
		if (line == "") { continue; }
		const fields = line.split(";");
		if (fields.length != 4 || fields[3].trim() != "") {
			throw new Error("invalid CaseFolding row");
		}
		const code = hexadecimal(fields[0].trim());
		const status = fields[1].trim();
		if (status != "C" && status != "F" && status != "S" && status != "T") {
			throw new Error("unknown CaseFolding status: " + status);
		}
		const mapped: int32[] = [];
		for (const word of fields[2].trim().split(" ")) {
			if (word != "") { mapped.push(hexadecimal(word)); }
		}
		if (mapped.length == 0 || mapped.length > 3) {
			throw new Error("casefold mapping exceeds pinned expansion bounds");
		}
		if (status == "S" || status == "T") { continue; }
		if (codes.length > 0 && codes[codes.length - 1] >= code) {
			throw new Error("casefold mappings are not unique and ordered");
		}
		if (status == "C" && mapped.length != 1) {
			throw new Error("common casefold mapping is not a singleton");
		}
		codes.push(code);
		for (const value of mapped) { values.push(value); }
		offsets.push(values.length as int32);
	}
	if (codes.length == 0 || offsets.length != codes.length + 1) {
		throw new Error("empty or invalid casefold tables");
	}
	return { codes, offsets, values };
}

function table(name: string, data: int32[]): string {
	let text = "export const " + name + ": int32[" + String(data.length) +
		"] = [\n";
	for (let i: int32 = 0; i < data.length; i += 1) {
		if (i % 8 == 0) { text += "\t"; }
		text += String(data[i]) + ",";
		if (i % 8 == 7 || i + 1 == data.length) { text += "\n"; }
		else { text += " "; }
	}
	return text + "];\n";
}

function generate(input: string): string {
	const read = readUtf8File(input);
	if (!read.ok) { throw new Error(read.error); }
	const digest = sha256(read.value);
	if (!digest.ok) { throw new Error(digest.error.message); }
	if (digest.value != DATA_SHA256) {
		throw new Error("casefold data cohort mismatch");
	}
	const rows = mappings(read.value);
	let text = "export const CASE_FOLD_VERSION = \"17.0.0\";\n";
	text += "export const CASE_FOLD_DATA_SHA256 =\n\t\"" + DATA_SHA256 +
		"\";\n\n";
	text += table("FOLD_CODES", rows.codes) + "\n";
	text += table("FOLD_OFFSETS", rows.offsets) + "\n";
	text += table("FOLD_VALUES", rows.values);
	return text;
}

when (!testBuild) {
	if (argv.length != 2) {
		throw new Error("usage: generateFileCaseFold.ms input");
	}
	writeStdout(generate(argv[1]));
}
