// msc download — fetch, verify, and extract packages from the registry.
//
// Flow:
//   1. fetch(archiveUrl) → raw zip bytes
//   2. sha256(bytes) == lockfile.integrity → verified
//   3. write to cache/download/registry/<name>/<version>.zip
//   4. extract to cache/extracted/<name>@<version>.partial/, then rename it to
//      cache/extracted/<name>@<version>/ (the rename is the commit)
//   5. every extracted file is chmod 0444

import { exists, writeFile, ensureDir, chmod, rename, removeAll } from "std/fs";
import { join, dirname } from "std/fs/path";
import { createHeaders } from "std/http/headers";
import { sha256 } from "std/crypto";
import { openZip, zipEntries, zipExtract, zipFindByName, closeZip, ZipReader, newZipWriter, zipAdd, zipFinalize, closeZipWriter } from "std/compress/zip";
import { tmpDir } from "../../utils/path";
import { registryDownloadPath, registrySrcPath } from "./cache";
import { isAbsoluteEntry, leavesPackage } from "./bin";

export enum PackageError {
	NoCacheDir,
	Download,
	HttpStatus,
	Integrity,
	BadArchive,
	UnsafePath,
	Write,
}

export function packageErrorMessage(e: PackageError): string {
	return match (e) {
		PackageError.NoCacheDir => "HOME not set, cannot resolve cache path",
		PackageError.Download => "download failed",
		PackageError.HttpStatus => "registry did not return HTTP 200",
		PackageError.Integrity => "integrity missing or mismatched",
		PackageError.BadArchive => "invalid zip archive",
		PackageError.UnsafePath => "archive entry would be written outside the package",
		PackageError.Write => "could not write the extracted files",
	};
}

function verifyIntegrity(archiveBytes: string, expectedIntegrity: string): Result<void, PackageError> {
	if (expectedIntegrity == "") return Result.err(PackageError.Integrity);
	const hash = sha256(archiveBytes, "base64");
	if (!hash.ok) return Result.err(PackageError.Integrity);
	if ("sha256-" + hash.value != expectedIntegrity) return Result.err(PackageError.Integrity);
	return Result.ok(null);
}

function entryRelativePath(entryName: string): string {
	if (entryName.length > 8 && entryName.slice(0, 8) == "package/") {
		return entryName.slice(8, entryName.length);
	}
	return entryName;
}

function writeEntries(reader: ZipReader, destDir: string): Result<int32, PackageError> {
	const entries = zipEntries(reader);
	let written: int32 = 0;
	for (const entry of entries) {
		if (entry.isDir) continue;
		const entryPath = entryRelativePath(entry.name);
		if (entryPath == "manifest.json") continue;
		if (isAbsoluteEntry(entryPath) || leavesPackage(entryPath)) return Result.err(PackageError.UnsafePath);

		const idx = zipFindByName(reader, entry.name);
		if (idx < 0) return Result.err(PackageError.BadArchive);
		const content = zipExtract(reader, idx);
		if (!content.ok) return Result.err(PackageError.BadArchive);

		const outPath = join(destDir, entryPath);
		if (!ensureDir(dirname(outPath)).ok) return Result.err(PackageError.Write);
		if (!writeFile(outPath, content.value).ok) return Result.err(PackageError.Write);
		if (!chmod(outPath, 292 as int32).ok) return Result.err(PackageError.Write);
		written = written + 1;
	}
	return Result.ok(written);
}

export function extractArchive(archiveBytes: string, destDir: string): Result<int32, PackageError> {
	const zip = openZip(archiveBytes);
	if (!zip.ok) return Result.err(PackageError.BadArchive);
	const result = writeEntries(zip.value, destDir);
	closeZip(zip.value);
	return result;
}

// Download and verify a package archive from the registry, then extract it.
// The extracted directory appears only after a complete extract.
export function downloadPackage(name: string, version: string, archiveUrl: string, expectedIntegrity: string): Result<void, PackageError> {
	const extractedPath = registrySrcPath(name, version);
	if (extractedPath == "") return Result.err(PackageError.NoCacheDir);
	if (exists(extractedPath)) return Result.ok(null);

	console.log(`  downloading ${name}@${version}...`);
	const resp = fetch(archiveUrl, {
		method: "GET",
		body: "",
		headers: createHeaders(),
		timeout: 60000,
		maxRedirects: 5,
	});
	if (!resp.ok) return Result.err(PackageError.Download);
	if (resp.value.status != 200) return Result.err(PackageError.HttpStatus);
	const archiveBytes = resp.value.body;

	const _verified = try verifyIntegrity(archiveBytes, expectedIntegrity);

	const dlPath = registryDownloadPath(name, version);
	if (dlPath != "") {
		if (!ensureDir(dirname(dlPath)).ok) return Result.err(PackageError.Write);
		if (!writeFile(dlPath, archiveBytes).ok) return Result.err(PackageError.Write);
	}

	const partialPath = extractedPath + ".partial";
	if (!removeAll(partialPath).ok) return Result.err(PackageError.Write);
	if (!ensureDir(partialPath).ok) return Result.err(PackageError.Write);
	const extracted = extractArchive(archiveBytes, partialPath);
	if (!extracted.ok) {
		removeAll(partialPath);
		return Result.err(extracted.error);
	}
	if (!rename(partialPath, extractedPath).ok) {
		removeAll(partialPath);
		return Result.err(PackageError.Write);
	}
	console.log(`  extracted ${name}@${version} (${extracted.value.toString()} files)`);
	return Result.ok(null);
}

function testArchive(names: string[]): string {
	const made = newZipWriter();
	if (!made.ok) return "";
	for (const n of names) {
		if (!zipAdd(made.value, n, "x").ok) return "";
	}
	const bytes = zipFinalize(made.value);
	closeZipWriter(made.value);
	if (!bytes.ok) return "";
	return bytes.value;
}

function freshDir(label: string): string {
	const dir = join(tmpDir(), "mscDownloadTest-" + label);
	removeAll(dir);
	ensureDir(dir);
	return dir;
}

test "a plain archive extracts with the package prefix stripped" {
	const dir = freshDir("plain");
	const r = extractArchive(testArchive(["package/lib/a.ms", "package/manifest.json"]), dir);
	assert r.ok;
	if (r.ok) assert r.value == 1;
	assert exists(join(dir, "lib/a.ms"));
	assert !exists(join(dir, "manifest.json"));
}

test "an entry with a parent segment is refused and writes nothing outside" {
	const dir = freshDir("dotdot");
	const inner = join(dir, "inner");
	ensureDir(inner);
	const r = extractArchive(testArchive(["package/../../escaped.txt"]), inner);
	assert !r.ok;
	if (!r.ok) assert r.error == PackageError.UnsafePath;
	assert !exists(join(dir, "escaped.txt"));
}

test "an absolute entry is refused" {
	const dir = freshDir("abs");
	const r = extractArchive(testArchive(["package//tmp/mscDownloadTestAbs.txt"]), dir);
	assert !r.ok;
	if (!r.ok) assert r.error == PackageError.UnsafePath;
	assert !exists("/tmp/mscDownloadTestAbs.txt");
}

test "bytes that are not a zip are refused" {
	const r = extractArchive("not a zip", freshDir("bad"));
	assert !r.ok;
	if (!r.ok) assert r.error == PackageError.BadArchive;
}

test "integrity must be present and match" {
	const bytes = testArchive(["package/a.ms"]);
	const good = sha256(bytes, "base64");
	assert good.ok;
	if (good.ok) assert verifyIntegrity(bytes, "sha256-" + good.value).ok;
	assert !verifyIntegrity(bytes, "").ok;
	assert !verifyIntegrity(bytes, "sha256-AAAA").ok;
}
