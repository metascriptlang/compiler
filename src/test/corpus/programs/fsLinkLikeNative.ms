// @stdout: link-like metadata ok
// @exit: 0
// @skip-js: Node lstat does not detect every Windows reparse tag
// @skip-raiser: native-only filesystem capability; no VM tier

import {
	basename,
	dirname,
	ensureDir,
	exists,
	isLinkLike,
	remove,
	resolve,
	rmdir,
	symlink,
	writeFile,
} from "std/fs";
import { argv, cwd, execFileResult, env, platform } from "std/process";
import { IoError, IoErrorKind } from "std/io/errors";

let cases: int32 = 0;

function completed(result: Result<void, IoError>): void {
	if (!result.ok) { throw new Error(result.error.message); }
}

function expectLink(path: string, expected: boolean, label: string): void {
	const result = isLinkLike(path);
	if (!result.ok) { throw new Error(label + ": " + result.error.message); }
	if (result.value != expected) { throw new Error(label + " differs"); }
	cases += 1;
}

function run(): void {
	const base = "out/fsLinkLikeNative-" + basename(dirname(argv[0])) +
		"-" + basename(argv[0]);
	if (exists(base)) { throw new Error("test output already exists: " + base); }
	completed(ensureDir(base));
	const root = resolve(base, cwd());
	const file = root + "/file.txt";
	const directory = root + "/target";
	const inside = directory + "/inside.txt";
	const fileLink = root + "/file-link";
	const directoryLink = root + "/dir-link";
	const dangling = root + "/dangling";
	const unicode = root + "/é日本ö.txt";
	const unicodeLink = root + "/é日本ö-link";
	completed(writeFile(file, "file"));
	completed(ensureDir(directory));
	completed(writeFile(inside, "inside"));
	completed(writeFile(unicode, "unicode"));
	completed(symlink(file, fileLink));
	completed(symlink(directory, directoryLink));
	completed(symlink(root + "/absent-target", dangling));
	completed(symlink(unicode, unicodeLink));
	expectLink(file, false, "regular file");
	expectLink(directory, false, "directory");
	expectLink(fileLink, true, "file symlink");
	expectLink(directoryLink, true, "directory symlink");
	expectLink(dangling, true, "dangling symlink");
	const missing = isLinkLike(root + "/missing");
	if (missing.ok || missing.error.kind != IoErrorKind.NotFound) {
		throw new Error("missing path did not preserve NotFound");
	}
	cases += 1;
	const invalidPath = file + "\0not-file";
	const invalid = isLinkLike(invalidPath);
	if (invalid.ok || invalid.error.path != invalidPath) {
		throw new Error("NUL path was silently truncated");
	}
	cases += 1;
	const ordinaryUnicode = isLinkLike(unicode);
	const linkedUnicode = isLinkLike(unicodeLink);
	if (!ordinaryUnicode.ok || !linkedUnicode.ok ||
		ordinaryUnicode.value || !linkedUnicode.value) {
		throw new Error("Unicode link metadata differs");
	}
	cases += 1;
	expectLink(directoryLink + "/inside.txt", false, "final component only");
	when (windows) {
		const junction = root + "/junction";
		const system = env.get("SystemRoot");
		if (system == "") { throw new Error("SystemRoot is unavailable"); }
		const made = execFileResult(system + "/System32/cmd.exe", [
			"/d", "/c", "mklink", "/J",
			junction.replaceAll("/", "\\"), directory.replaceAll("/", "\\"),
		]);
		if (!made.started || !made.pipeOk || made.exitCode != 0) {
			throw new Error("junction fixture failed: " + made.errorOutput);
		}
		expectLink(junction, true, "directory junction");
		completed(rmdir(junction));
	}
	const expectedCases: int32 = platform == "windows" ? 10 : 9;
	if (cases != expectedCases) { throw new Error("metadata case count differs"); }
	for (const link of [fileLink, dangling, unicodeLink]) {
		completed(remove(link));
	}
	when (windows) {
		completed(rmdir(directoryLink));
	} else {
		completed(remove(directoryLink));
	}
	for (const path of [file, inside, unicode]) { completed(remove(path)); }
	completed(rmdir(directory));
	completed(rmdir(base));
	console.log("link-like metadata ok");
}

when (!testBuild) { run(); }
