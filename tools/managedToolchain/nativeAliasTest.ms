import { verifyStoredRelativeTarget } from "./nativeAlias";
import { createDirectoryExclusive, renameNoReplace } from "./nativePublication";
import {
	basename, exists, readFile, remove, resolve, rmdir, symlink, writeFile,
} from "std/fs";
import { argv, cwd } from "std/process";
import { IoError, IoErrorKind } from "std/io/errors";

let cases: int32 = 0;

function completed(result: Result<void, IoError>): void {
	if (!result.ok) { throw new Error(result.error.message); }
}

function accepted(path: string, target: string): void {
	completed(verifyStoredRelativeTarget(path, target));
	cases += 1;
}

function refused(path: string, target: string): void {
	const result = verifyStoredRelativeTarget(path, target);
	if (result.ok || result.error.path != path) {
		throw new Error("alias was accepted or lost its path");
	}
	cases += 1;
}

function run(): void {
	const parentCwd = cwd();
	const root = resolve("out/aliases-" + basename(argv[0]) + " é", parentCwd);
	const relocated = root + " moved 日本";
	if (exists(root) || exists(relocated)) {
		throw new Error("alias fixture output already exists");
	}
	completed(createDirectoryExclusive(root));
	const targetName = "libsample.so.1";
	const target = root + "/" + targetName;
	const alias = root + "/libsample.so";
	completed(writeFile(target, "alias bytes"));
	completed(symlink(targetName, alias));
	accepted(alias, targetName);
	refused(alias, "different.a");
	const absolute = root + "/absolute alias";
	completed(symlink(target, absolute));
	refused(absolute, targetName);
	refused(target, targetName);
	const missingPath = root + "/missing alias";
	const missing = verifyStoredRelativeTarget(missingPath, targetName);
	if (missing.ok || missing.error.kind != IoErrorKind.NotFound ||
		missing.error.path != missingPath) {
		throw new Error("missing alias lost its NotFound error");
	}
	cases += 1;
	const dangling = root + "/dangling alias";
	completed(symlink("missing-target.a", dangling));
	accepted(dangling, "missing-target.a");
	for (const invalid of [
		"", ".", "..", "../target", "a/b", "a\\b", "C:x", "nul\0suffix",
	]) { refused(alias, invalid); }
	refused(alias + "\0suffix", targetName);
	const unicodeName = "é日本🚀.a";
	completed(writeFile(root + "/" + unicodeName, "unicode target"));
	const unicodeAliasName = "unicode alias.a";
	completed(symlink(unicodeName, root + "/" + unicodeAliasName));
	accepted(root + "/" + unicodeAliasName, unicodeName);
	const chainedName = "chained alias.a";
	completed(symlink("libsample.so", root + "/" + chainedName));
	accepted(root + "/" + chainedName, "libsample.so");
	completed(renameNoReplace(root, relocated));
	accepted(relocated + "/libsample.so", targetName);
	const read = readFile(relocated + "/libsample.so");
	if (!read.ok || read.value != "alias bytes") {
		throw new Error("relative alias broke after relocation");
	}
	cases += 1;
	if (cwd() != parentCwd) { throw new Error("alias query changed parent cwd"); }
	cases += 1;
	for (const name of [
		targetName, "libsample.so", "absolute alias", "dangling alias",
		unicodeName, unicodeAliasName, chainedName,
	]) { completed(remove(relocated + "/" + name)); }
	completed(rmdir(relocated));
	console.log("stored relative aliases: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
