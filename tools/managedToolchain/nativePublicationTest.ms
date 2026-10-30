import { createDirectoryExclusive, renameNoReplace } from "./nativePublication";
import {
	basename, exists, isDir, readFile, remove, resolve, rmdir, symlink, writeFile,
} from "std/fs";
import { argv, cwd } from "std/process";
import { IoError, IoErrorKind } from "std/io/errors";

let cases: int32 = 0;

function completed(result: Result<void, IoError>): void {
	if (!result.ok) { throw new Error(result.error.message); }
}

function content(path: string): string {
	const read = readFile(path);
	if (!read.ok) { throw new Error(read.error.message); }
	return read.value;
}

function expect(condition: boolean, label: string): void {
	if (!condition) { throw new Error(label); }
	cases += 1;
}

function refused(result: Result<void, IoError>, label: string): void {
	if (result.ok) { throw new Error(label + " was accepted"); }
}

function run(): void {
	const parentCwd = cwd();
	const root = resolve(
		"out/publication-" + basename(argv[0]) + " é日本", parentCwd,
	);
	if (exists(root)) {
		throw new Error("test artifacts already exist: " + root);
	}
	completed(createDirectoryExclusive(root));
	expect(isDir(root), "exclusive create did not create a directory");
	const again = createDirectoryExclusive(root);
	expect(!again.ok && again.error.kind == IoErrorKind.AlreadyExists &&
		again.error.path == root, "existing directory was accepted");
	const collision = root + "/existing file";
	completed(writeFile(collision, "untouched"));
	const fileCollision = createDirectoryExclusive(collision);
	expect(!fileCollision.ok && content(collision) == "untouched",
		"exclusive create changed an existing file");
	const nested = createDirectoryExclusive(root + "/missing/child");
	expect(!nested.ok && nested.error.kind == IoErrorKind.NotFound &&
		!exists(root + "/missing"), "create made missing parents");
	const nulDirectory = root + "/new\0suffix";
	const nulCreated = createDirectoryExclusive(nulDirectory);
	expect(!nulCreated.ok && nulCreated.error.path == nulDirectory &&
		!exists(root + "/new"), "NUL directory path was truncated");

	const stage = root + "/stage é";
	const published = root + "/published 日本";
	completed(createDirectoryExclusive(stage));
	completed(writeFile(stage + "/marker", "ready"));
	completed(renameNoReplace(stage, published));
	expect(!exists(stage) && content(published + "/marker") == "ready",
		"directory publication changed its content");

	const sourceFile = root + "/source file";
	const targetFile = root + "/target file";
	completed(writeFile(sourceFile, "source"));
	completed(writeFile(targetFile, "target"));
	const replacedFile = renameNoReplace(sourceFile, targetFile);
	expect(!replacedFile.ok && content(sourceFile) == "source" &&
		content(targetFile) == "target", "publication replaced a file");

	const sourceDirectory = root + "/source directory";
	const emptyDirectory = root + "/empty directory";
	const fullDirectory = root + "/full directory";
	for (const directory of [sourceDirectory, emptyDirectory, fullDirectory]) {
		completed(createDirectoryExclusive(directory));
	}
	completed(writeFile(sourceDirectory + "/marker", "source directory"));
	completed(writeFile(fullDirectory + "/marker", "target directory"));
	const replacedEmpty = renameNoReplace(sourceDirectory, emptyDirectory);
	expect(!replacedEmpty.ok && isDir(emptyDirectory) &&
		!exists(emptyDirectory + "/marker") &&
		content(sourceDirectory + "/marker") == "source directory",
		"publication replaced an empty directory");
	const replacedFull = renameNoReplace(sourceDirectory, fullDirectory);
	expect(!replacedFull.ok &&
		content(sourceDirectory + "/marker") == "source directory" &&
		content(fullDirectory + "/marker") == "target directory",
		"publication replaced a nonempty directory");

	const absentTarget = root + "/absent target";
	const missing = renameNoReplace(root + "/absent source", absentTarget);
	expect(!missing.ok && missing.error.kind == IoErrorKind.NotFound &&
		!exists(absentTarget), "missing source publication was accepted");
	const nulSource = sourceFile + "\0suffix";
	const invalidSource = renameNoReplace(nulSource, absentTarget);
	expect(!invalidSource.ok && invalidSource.error.path == nulSource &&
		content(sourceFile) == "source" && !exists(absentTarget),
		"NUL source was truncated");
	const nulTarget = absentTarget + "\0suffix";
	const invalidTarget = renameNoReplace(sourceFile, nulTarget);
	expect(!invalidTarget.ok && invalidTarget.error.path == nulTarget &&
		content(sourceFile) == "source" && !exists(absentTarget),
		"NUL destination was truncated");

	const movedFile = root + "/moved file";
	completed(renameNoReplace(targetFile, movedFile));
	expect(!exists(targetFile) && content(movedFile) == "target",
		"file publication changed bytes");
	const dangling = root + "/dangling alias";
	completed(symlink(root + "/missing alias target", dangling));
	const replacedLink = renameNoReplace(sourceFile, dangling);
	refused(replacedLink, "dangling destination");
	expect(content(sourceFile) == "source",
		"publication consumed its source at a dangling destination");
	expect(cwd() == parentCwd, "publication changed parent cwd");

	completed(remove(dangling));
	for (const file of [
		collision, sourceFile, movedFile, published + "/marker",
		sourceDirectory + "/marker", fullDirectory + "/marker",
	]) { completed(remove(file)); }
	for (const directory of [
		published, sourceDirectory, emptyDirectory, fullDirectory, root,
	]) { completed(rmdir(directory)); }
	console.log("native publication: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
