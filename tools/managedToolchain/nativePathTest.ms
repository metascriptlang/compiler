import { samePhysicalFile, containsExistingRoot } from "./nativePath";
import {
	ensureDir, join, removeAll, resolve, symlink, writeFile,
} from "std/fs";
import { argv, cwd, platform } from "std/process";
import { IoError } from "std/io/errors";
import { createDirectoryExclusive } from "./nativePublication";

when (windows) {
	@include("windows.h");
	import { freeWide, widePath } from "std/fs/widePath";
	extern function CreateHardLinkW(
		path: Ptr<uint16>, target: Ptr<uint16>, reserved: Ptr<void> | null,
	): int32;

	function makeHardLink(target: string, path: string): boolean {
		const wideTarget = widePath(target);
		const widePathname = widePath(path);
		if (wideTarget == null || widePathname == null) {
			freeWide(wideTarget);
			freeWide(widePathname);
			return false;
		}
		const made = CreateHardLinkW(widePathname, wideTarget, null) != 0;
		freeWide(wideTarget);
		freeWide(widePathname);
		return made;
	}
} else {
	@include("unistd.h");
	extern function cLink(target: cstring, path: cstring): int32 from "link";

	function makeHardLink(target: string, path: string): boolean {
		return cLink(target as cstring, path as cstring) == 0;
	}
}

let checks: int32 = 0;
let skipped: int32 = 0;
function check(condition: boolean, label: string): void {
	if (!condition) { throw new Error(label); }
	checks += 1;
}

function skip(label: string, error: IoError, count: int32): void {
	skipped += count;
	console.log("SKIP " + label + " (" + String(count) + " checks): " +
		error.message);
}

function must(result: Result<void, IoError>): void {
	if (!result.ok) { throw new Error(result.error.message); }
}

function same(
	left: string, right: string, expected: boolean, label: string,
): void {
	const got = samePhysicalFile(left, right);
	if (!got.ok) { throw new Error(label + ": " + got.error.message); }
	check(got.value == expected, label);
}

function inside(
	root: string, child: string, expected: boolean, label: string,
): void {
	const got = containsExistingRoot(root, child);
	if (!got.ok) { throw new Error(label + ": " + got.error.message); }
	check(got.value == expected, label);
}

if (argv.length != 2) {
	throw new Error("usage: nativePathTest.ms new-private-directory");
}
const root = resolve(argv[1], cwd());
must(createDirectoryExclusive(root));
const source = join(root, "source Δ");
const nested = join(source, "nested");
must(ensureDir(nested));
const a = join(source, "actual Δ.txt");
const b = join(root, "same-content.txt");
must(writeFile(a, "identical contents"));
must(writeFile(b, "identical contents"));
const fileAlias = join(root, "file-alias");
const directoryAlias = join(root, "directory-alias");
const nestedAlias = join(root, "nested-alias");
const hardAlias = join(root, "hard-alias");
const fileLinked = symlink(a, fileAlias);
const directoryLinked = symlink(source, directoryAlias);
const nestedLinked = symlink(nested, nestedAlias);
if (!makeHardLink(a, hardAlias)) { throw new Error("hardlink fixture failed"); }

same(a, a, true, "file identity");
same(a, b, false, "same content is not same identity");
if (fileLinked.ok) {
	same(a, fileAlias, true, "file symlink follows target identity");
} else { skip("file symlink fixture", fileLinked.error, 2); }
if (directoryLinked.ok) {
	same(source, directoryAlias, true, "directory symlink follows identity");
} else { skip("directory symlink fixture", directoryLinked.error, 3); }
same(a, hardAlias, true, "hardlink shares identity without path equality");
same(source, a, false, "directory and file are distinct");
if (platform == "windows") {
	same(a, a.toUpperCase(), true, "Windows path spelling is not identity");
}
inside(source, source, true, "root contains itself");
inside(source, a, true, "physical descendant");
if (fileLinked.ok) {
	inside(source, fileAlias, true, "file alias resolves before ancestry");
}
if (directoryLinked.ok) {
	inside(source, join(directoryAlias, "actual Δ.txt"), true,
		"directory alias resolves before ancestry");
	const missingSuffix = join(join(directoryAlias, "missing"), "deep");
	inside(source, join(missingSuffix, "output"), true,
		"missing suffix follows an existing linked ancestor");
}
if (nestedLinked.ok) {
	inside(source, join(nestedAlias, "new-output"), true,
		"alias to a nested directory still has the root as ancestor");
} else { skip("nested symlink fixture", nestedLinked.error, 1); }
inside(source, b, false, "outside sibling");
inside(source, source + "-other/missing", false,
	"textual prefix is not containment");
const missing = samePhysicalFile(a, join(root, "absent"));
check(!missing.ok, "missing metadata is an error, not false");
const leftNul = samePhysicalFile(a + "\0suffix", a);
check(!leftNul.ok, "left NUL refused");
const rightNul = samePhysicalFile(a, a + "\0suffix");
check(!rightNul.ok, "right NUL refused");
check(removeAll(root).ok, "successful private fixture cleanup");
if (checks + skipped != (platform == "windows" ? 19 : 18)) {
	throw new Error("native path case count changed");
}
console.log("Native paths: " + String(checks) + " checks OK; " +
	String(skipped) + " skipped");
