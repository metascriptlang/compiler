// @stdout: binary roundtrip true
// @stdout: text repair true
// @stdout: all bytes copy true
// @stdout: empty bytes 0
// @stdout: missing refused true
// @exit: 0

import { argv } from "std/process";
import { basename, dirname } from "std/fs/path";
import {
	exists, ensureDir, readFile, readFileBytes, writeFileBytes, copyFile,
	remove, rmdir,
} from "std/fs";
import { IoError, IoErrorKind } from "std/io/errors";

function must<T>(result: Result<T, IoError>): T {
	if (!result.ok) { throw new Error(result.error.message); }
	return result.value;
}

function checkCompleted(result: Result<void, IoError>): void {
	if (!result.ok) { throw new Error(result.error.message); }
}

function same(a: Buffer, b: Buffer): boolean {
	if (a.length != b.length) { return false; }
	for (let i: int32 = 0; i < a.length; i += 1) {
		if (a[i] != b[i]) { return false; }
	}
	return true;
}

function run(): void {
	const dir = "out/fsByteRoundtrip-" + basename(dirname(argv[0])) +
		"-" + basename(argv[0]);
	if (exists(dir)) { throw new Error("test output already exists: " + dir); }
	checkCompleted(ensureDir(dir));
	const path = dir + "/bytes.bin";
	const copy = dir + "/copy.bin";
	let binary: Buffer = [0, 255, 195, 40, 0, 128, 10, 13, 127];
	when (js) {
		binary = Buffer.fromArray([0, 255, 195, 40, 0, 128, 10, 13, 127]);
	}
	checkCompleted(writeFileBytes(path, binary));
	console.log("binary roundtrip", same(must(readFileBytes(path)), binary));
	const text = must(readFile(path));
	console.log("text repair", text.charCodeAt(1) == 65533 &&
		text.charCodeAt(2) == 65533 && text.charCodeAt(5) == 65533);
	let all: Buffer = [];
	when (js) {
		all = Buffer.alloc(256);
		for (let i: int32 = 0; i < 256; i += 1) { all[i] = i as uint8; }
	} else {
		for (let i: int32 = 0; i < 256; i += 1) { all.push(i as uint8); }
	}
	checkCompleted(writeFileBytes(path, all));
	checkCompleted(copyFile(path, copy));
	console.log("all bytes copy", same(must(readFileBytes(copy)), all));
	let empty: Buffer = [];
	when (js) { empty = Buffer.alloc(0); }
	checkCompleted(writeFileBytes(path, empty));
	console.log("empty bytes", must(readFileBytes(path)).length);
	const absent = dir + "/absent";
	const missing = readFileBytes(absent);
	console.log("missing refused", !missing.ok &&
		missing.error.kind == IoErrorKind.NotFound && missing.error.path == absent);
	checkCompleted(remove(path));
	checkCompleted(remove(copy));
	checkCompleted(rmdir(dir));
}
run();
