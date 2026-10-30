import { ensureDir, exists, remove, rmdir, writeFileBytes } from "std/fs";
import { readUtf8File } from "./textFile";

const DIRECTORY = "out/textFileTest";
let cases: int32 = 0;

function writeBytes(path: string, data: Buffer): void {
	const written = writeFileBytes(path, data);
	if (!written.ok) { throw new Error(written.error.message); }
}

function run(): void {
	if (exists(DIRECTORY)) {
		throw new Error("test output already exists: " + DIRECTORY);
	}
	const created = ensureDir(DIRECTORY);
	if (!created.ok) { throw new Error(created.error.message); }
	const path = DIRECTORY + "/metadata with spaces.txt";
	for (const expected of [
		"", "abc", "\uFFFD", "\uFEFFheader", "line\r\nnext\n", "高🚀",
	]) {
		writeBytes(path, Buffer.fromString(expected, "utf8"));
		const read = readUtf8File(path);
		if (!read.ok) { throw new Error(read.error); }
		if (read.value != expected) { throw new Error("text bytes changed"); }
		cases += 1;
	}
	for (const invalid of [
		[255], [128], [192, 175], [224, 128, 175], [237, 160, 128],
		[244, 144, 128, 128], [226, 130], [97, 255, 98],
	]) {
		const data: Buffer = [];
		for (const byte of invalid) { data.push(byte as uint8); }
		writeBytes(path, data);
		const read = readUtf8File(path);
		if (read.ok || read.error.indexOf("not UTF-8: " + path) < 0) {
			throw new Error("ill-formed metadata was repaired or accepted");
		}
		cases += 1;
	}
	const absent = DIRECTORY + "/absent";
	const missing = readUtf8File(absent);
	if (missing.ok || missing.error.indexOf("cannot read " + absent) < 0) {
		throw new Error("missing metadata was not refused with its path");
	}
	cases += 1;
	const removed = remove(path);
	if (!removed.ok) { throw new Error(removed.error.message); }
	const directoryRemoved = rmdir(DIRECTORY);
	if (!directoryRemoved.ok) { throw new Error(directoryRemoved.error.message); }
	console.log("strict UTF-8 files: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
