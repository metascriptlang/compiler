import {
	isDir, isFile, isLinkLike, readDirNames, writeFile, copyFile,
	ensureDir, dirname, join, fileSize,
} from "std/fs";
import { IoError } from "std/io/errors";
import { containsExistingRoot, absoluteNativePath } from "./nativePath";
import { isSymbolicLink } from "./nativeAlias";
import { sha256File } from "./fileDigest";
import { readUtf8File } from "./textFile";
import {
	ManifestEntry, ContractHeader, parseHeader, parseManifest,
	renderManifest, manifestIdentity, verifyIdentity,
} from "./manifest";

export enum FileLinks {
	ContainedFiles,
	Refuse,
}

export struct EngineContract {
	host: string;
	version: string;
	identity: string;
	files: int32;
}

export function absoluteEnginePath(path: string): Result<string, string> {
	const absolute = absoluteNativePath(path);
	if (!absolute.ok) { return Result.err(absolute.error.message); }
	return Result.ok(absolute.value);
}

function comparePaths(left: string, right: string): number {
	const a = left.asBytes();
	const b = right.asBytes();
	const count = a.length < b.length ? a.length : b.length;
	for (let i: int64 = 0; i < count; i += 1) {
		if (a[i] < b[i]) { return -1; }
		if (a[i] > b[i]) { return 1; }
	}
	return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
}

export function sortEnginePaths(paths: string[]): void {
	paths.sort(comparePaths);
}

export function engineIo(result: Result<void, IoError>): Result<void, string> {
	if (!result.ok) { return Result.err(result.error.message); }
	return Result.ok(null);
}

export function inventoryTree(
	root: string, fileLinks: FileLinks,
): Result<string[], string> {
	if (!isDir(root)) { return Result.err("not a directory: " + root); }
	const files: string[] = [];
	const pending = [""];
	while (pending.length > 0) {
		const prefix = pending.pop();
		const directory = prefix == "" ? root : join(root, prefix);
		const entries = readDirNames(directory);
		if (!entries.ok) { return Result.err(entries.error.message); }
		for (const name of entries.value) {
			const rel = prefix == "" ? name : prefix + "/" + name;
			if (rel.indexOf("\n") >= 0 || rel.indexOf("\r") >= 0 ||
				rel.indexOf("\\") >= 0) {
				return Result.err("unsupported character in path: " + rel);
			}
			const path = join(root, rel);
			const linked = isLinkLike(path);
			if (!linked.ok) { return Result.err(linked.error.message); }
			if (linked.value && fileLinks == FileLinks.Refuse) {
				return Result.err("symlink in resource directory: " + name);
			}
			if (isDir(path)) {
				if (linked.value) {
					return Result.err("directory symlink or reparse point: " + path);
				}
				pending.push(rel);
				continue;
			}
			if (!isFile(path)) {
				return Result.err("not a regular file: " + path);
			}
			if (linked.value) {
				const symbolic = isSymbolicLink(path);
				if (!symbolic.ok) { return Result.err(symbolic.error.message); }
				if (symbolic.value) {
					const contained = containsExistingRoot(root, path);
					if (!contained.ok) { return Result.err(contained.error.message); }
					if (!contained.value) {
						return Result.err("symlink leaves the bundle: " + rel);
					}
				}
			}
			files.push(rel);
		}
	}
	sortEnginePaths(files);
	return Result.ok(files);
}

export function listEngineFiles(root: string): Result<string[], string> {
	const inventory = try inventoryTree(root, FileLinks.ContainedFiles);
	const files: string[] = [];
	for (const path of inventory) {
		if (path != "FILES.sha256" && path != "IDENTITY") { files.push(path); }
	}
	return Result.ok(files);
}

export function engineFileSize(path: string): Result<int64, string> {
	const size = fileSize(path);
	if (size != size || size < 0 || size > 9007199254740991) {
		return Result.err("file size unavailable or not exact: " + path);
	}
	return Result.ok(size as int64);
}

export function engineByteCount(root: string): Result<int64, string> {
	let total: int64 = 0;
	for (const path of try listEngineFiles(root)) {
		const size = try engineFileSize(join(root, path));
		if (total > (9223372036854775807 as int64) - size) {
			return Result.err("engine byte count overflows int64");
		}
		total += size;
	}
	return Result.ok(total);
}

export function writeEngineText(
	path: string, text: string,
): Result<void, string> {
	return engineIo(writeFile(path, text));
}

export function copyEngineFile(
	source: string, target: string,
): Result<void, string> {
	try engineIo(ensureDir(dirname(target)));
	return engineIo(copyFile(source, target));
}

export function writeEngineContract(
	root: string, host: string, version: string,
): Result<void, string> {
	try parseHeader(host + "\n", version + "\n");
	try writeEngineText(join(root, "HOST"), host + "\n");
	try writeEngineText(join(root, "VERSION"), version + "\n");
	const files = try listEngineFiles(root);
	const entries: ManifestEntry[] = [];
	for (const path of files) {
		entries.push({ path, digest: try sha256File(join(root, path)) });
	}
	const text = try renderManifest(entries);
	try writeEngineText(join(root, "FILES.sha256"), text);
	return writeEngineText(join(root, "IDENTITY"), try manifestIdentity(text));
}

export function readEngineHeader(root: string): Result<ContractHeader, string> {
	return parseHeader(
		try readUtf8File(join(root, "HOST")),
		try readUtf8File(join(root, "VERSION")),
	);
}

export function verifyEngineContract(
	root: string,
): Result<EngineContract, string> {
	const header = try readEngineHeader(root);
	const text = try readUtf8File(join(root, "FILES.sha256"));
	const entries = try parseManifest(text);
	const actual = try listEngineFiles(root);
	if (entries.length != actual.length) {
		return Result.err("FILES.sha256: inventory file count differs");
	}
	let hasHost = false;
	let hasVersion = false;
	for (let i: int32 = 0; i < entries.length; i += 1) {
		const entry = entries[i];
		if (entry.path != actual[i]) {
			return Result.err("FILES.sha256: inventory differs at " + actual[i]);
		}
		const digest = try sha256File(join(root, entry.path));
		if (digest != entry.digest) {
			return Result.err("hash mismatch: " + entry.path);
		}
		if (entry.path == "HOST") { hasHost = true; }
		if (entry.path == "VERSION") { hasVersion = true; }
	}
	if (!hasHost || !hasVersion) {
		return Result.err("FILES.sha256 omits HOST or VERSION");
	}
	const identity = try readUtf8File(join(root, "IDENTITY"));
	try verifyIdentity(text, identity);
	return Result.ok({
		host: header.host, version: header.version,
		identity: identity.slice(0, identity.length - 1), files: actual.length,
	});
}
