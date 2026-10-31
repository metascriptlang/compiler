// @stdout: Directory names: 15 checks OK
// @skip-js: native fallible directory enumeration
// @skip-raiser: native fallible directory enumeration

import {
	basename, join, readDirNames, readDir, mkdir, remove, rmdir, writeFile,
} from "std/fs";
import { argv } from "std/process";
import { IoError, IoErrorKind } from "std/io/errors";

when (windows) {
	@include("windows.h");
	import { widePath, freeWide, allocWide } from "std/fs/widePath";
	extern const CREATE_NEW: uint32;
	extern const FILE_ATTRIBUTE_NORMAL: uint32;
	extern const INVALID_HANDLE_VALUE: Ptr<void>;
	extern function GetLastError(): uint32;
	extern function CloseHandle(handle: Ptr<void>): int32;
	extern function DeleteFileW(path: Ptr<uint16>): int32;
	extern function CreateFileW(
		path: Ptr<uint16>, access: uint32, share: uint32,
		security: Ptr<void> | null, disposition: uint32, flags: uint32,
		template: Ptr<void> | null,
	): Ptr<void>;
	extern function CreateDirectoryW(
		path: Ptr<uint16>, security: Ptr<void> | null,
	): int32;
	function claim(path: string): void {
		const wide = widePath(path);
		if (wide == null) { throw new Error("fixture path cannot encode"); }
		const made = CreateDirectoryW(wide, null);
		freeWide(wide);
		if (made == 0) { throw new Error("fixture directory not newly created"); }
	}
	function invalidNameFixture(root: string): void {
		const prefix = widePath(join(root, "invalid-"));
		if (prefix == null) { throw new Error("fixture prefix cannot encode"); }
		defer freeWide(prefix);
		let units: int32 = 0;
		while (prefix[units] != 0) { units += 1; }
		const invalid = allocWide((units + 2) as uint64);
		if (invalid == null) { throw new Error("fixture path allocation failed"); }
		defer freeWide(invalid);
		for (let i: int32 = 0; i < units; i += 1) { invalid[i] = prefix[i]; }
		invalid[units] = 0xd800;
		invalid[units + 1] = 0;
		const handle = CreateFileW(invalid, 0, 0, null, CREATE_NEW,
			FILE_ATTRIBUTE_NORMAL, null);
		const error = handle == INVALID_HANDLE_VALUE ? GetLastError() : 0;
		if (handle == INVALID_HANDLE_VALUE) {
			throw new Error("raw UTF16 fixture creation failed: " + String(error));
		}
		if (CloseHandle(handle) == 0) { throw new Error("fixture close failed"); }
		const refused = readDirNames(root);
		check(!refused.ok && refused.error.path == root,
			"unpaired UTF-16 name must not be replaced");
		if (DeleteFileW(invalid) == 0) { throw new Error("fixture delete failed"); }
	}
} else {
	@include("sys/stat.h");
	extern function cMkdir(path: cstring, mode: uint32): int32 from "mkdir";
	function claim(path: string): void {
		if (cMkdir(path as cstring, 0o700) != 0) {
			throw new Error("fixture directory not newly created");
		}
	}
}

let checks: int32 = 0;
function check(ok: boolean, label: string): void {
	if (!ok) { throw new Error(label); }
	checks += 1;
}
function completed(result: Result<void, IoError>): void {
	if (!result.ok) { throw new Error(result.error.message); }
}
function names(path: string): string[] {
	const result = readDirNames(path);
	if (!result.ok) { throw new Error(result.error.message); }
	return result.value;
}
function has(items: string[], wanted: string): boolean {
	for (const item of items) { if (item == wanted) { return true; } }
	return false;
}
function run(): void {
	const root = argv.length > 1 ? argv[1] :
		"out/fsDirectoryNames-" + basename(argv[0]);
	claim(root);
	check(names(root).length == 0, "empty directory is not an error");
	const files = ["plain", "đệ日本🚀", ".hidden", "literal-�"];
	for (const name of files) { completed(writeFile(join(root, name), "")); }
	completed(mkdir(join(root, "sub")));
	const listed = names(root);
	check(listed.length == 5, "only immediate names");
	for (const name of files) {
		check(has(listed, name), "filename changed: " + name);
	}
	check(has(listed, "sub"), "directory name without a suffix");
	check(!has(listed, ".") && !has(listed, "..") && !has(listed, "sub/"),
		"no dot entries or synthetic directory markers");
	const absent = readDirNames(join(root, "missing"));
	check(!absent.ok && absent.error.kind == IoErrorKind.NotFound,
		"missing directory must not become an empty success");
	const file = readDirNames(join(root, "plain"));
	check(!file.ok && file.error.kind == IoErrorKind.NotDirectory,
		"regular file must preserve NotDirectory");
	const nul = readDirNames(root + "\0ignored");
	check(!nul.ok && nul.error.path == root + "\0ignored",
		"embedded NUL must not truncate the path");
	const growth: string[] = [];
	for (let i: int32 = 0; i < 128; i += 1) {
		const name = "entry-" + "x".repeat(48) + String(i);
		growth.push(name);
		completed(writeFile(join(root, name), ""));
	}
	const grown = names(root);
	check(grown.length == 133, "native name buffer must grow");
	for (const name of growth) {
		if (!has(grown, name)) { throw new Error("growth lost " + name); }
	}
	check(true, "every grown name retained");
	const legacy = readDir(root);
	check(legacy.length == 133 && has(legacy, "sub/"),
		"legacy readDir markers stay unchanged");
	when (windows) {
		invalidNameFixture(root);
	} else {
		const newline = "embedded\nnewline";
		completed(writeFile(join(root, newline), ""));
		check(has(names(root), newline), "newline is part of one filename");
		completed(remove(join(root, newline)));
	}
	if (checks != 15) { throw new Error("directory check count changed"); }
	for (const name of files) { completed(remove(join(root, name))); }
	for (const name of growth) { completed(remove(join(root, name))); }
	completed(rmdir(join(root, "sub")));
	completed(rmdir(root));
	console.log("Directory names: 15 checks OK");
}
run();
