import { IoError } from "../io/errors";
import { exists, isDir, readDir, rmdir, remove, readFile, writeFile } from "./kernel";

export { dirname, basename, extname, join, resolve, isAbsolute, normalize } from "./path";
export { readFile, writeFile, appendFile, chmod, mkdir, rmdir, remove, symlink, rename, exists, realpath, isFile, isDir, isExecutable, fileSize, modifiedTime, changeStamp, readDir, ensureDir } from "./kernel";

// Recursively remove a file or directory tree, Go-style. Mirrors
// `os.RemoveAll`: a non-existent path returns ok so callers can clean up
// without racing isExist checks. Walks children depth-first, then rmdir's
// the root. Companion to `remove` (file only) for explicit intent —
// no boolean flag to misuse, two names read as the thing they do.
//
// Uses recursion — fine for msc cache layouts (~2 levels). Not suitable
// for pathological trees (> ~1000 deep). Symlink handling follows
// whatever runtime/fs/*.c does for remove().
export function removeAll(path: string): Result<void, IoError> {
	if (!exists(path)) return Result.ok(null);
	if (isDir(path)) {
		for (const entry of readDir(path)) {
			// readDir marks directories with a trailing "/" — strip for the child path.
			const name = entry.endsWith("/") ? entry.slice(0, entry.length - 1) : entry;
			const r = removeAll(path + "/" + name);
			if (!r.ok) return r;
		}
		return rmdir(path);
	}
	return remove(path);
}

export function readLines(path: string): Result<string[], IoError> {
	const content = try readFile(path);
	if (content.length == 0) return Result.ok([]);
	return Result.ok(content.split("\n"));
}

export function writeLines(path: string, lines: string[]): Result<void, IoError> {
	return writeFile(path, lines.join("\n"));
}

export function copyFile(src: string, dst: string): Result<void, IoError> {
	const content = try readFile(src);
	return writeFile(dst, content);
}
