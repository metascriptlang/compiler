// msc download — fetch, verify, and extract packages from the registry.
//
// Flow:
//   1. fetch(archiveUrl) → raw zip bytes
//   2. sha256(bytes) == lockfile.integrity → verified
//   3. write to cache/download/<name>/<version>.zip
//   4. extract to cache/extracted/<name>@<version>/
//   5. chmod -R read-only on extracted dir

import { exists, writeFile, ensureDir, chmod } from "std/fs";
import { join, dirname } from "std/fs/path";
import { createHeaders } from "std/http/headers";
import { sha256 } from "std/crypto";
import { openZip, zipEntries, zipExtract, zipFindByName, closeZip } from "std/compress/zip";
import { registryDownloadPath, registrySrcPath } from "./cache";

// Download and verify a package archive from the registry.
// Returns true on success. On failure prints an error and returns false.
export function downloadPackage(name: string, version: string, archiveUrl: string, expectedIntegrity: string): boolean {
	// Check if already extracted
	const extractedPath = registrySrcPath(name, version);
	if (extractedPath == "" ) {
		console.log("error: HOME not set, cannot resolve cache path");
		return false;
	}
	if (exists(extractedPath)) return true; // already cached

	// Step 1: Download
	console.log(`  downloading ${name}@${version}...`);
	const resp = fetch(archiveUrl, {
		method: "GET",
		body: "",
		headers: createHeaders(),
		timeout: 60000,
		maxRedirects: 5,
	});
	if (!resp.ok) {
		console.log(`  error: download failed: ${resp.error.message}`);
		return false;
	}
	if (resp.value.status != 200) {
		console.log(`  error: registry returned HTTP ${resp.value.status.toString()}`);
		return false;
	}
	const archiveBytes = resp.value.body;

	// Step 2: Verify integrity (SHA-256, W3C SRI format: "sha256-<base64>")
	if (expectedIntegrity != "") {
		const hashR = sha256(archiveBytes, "base64");
		if (hashR.ok) {
			const computed = "sha256-" + hashR.value;
			if (computed != expectedIntegrity) {
				console.log(`  error: integrity mismatch for ${name}@${version}`);
				console.log(`    expected: ${expectedIntegrity}`);
				console.log(`    got:      ${computed}`);
				return false;
			}
		}
	}

	// Step 3: Save archive to cache/download/
	const dlPath = registryDownloadPath(name, version);
	if (dlPath != "") {
		ensureDir(dirname(dlPath));
		writeFile(dlPath, archiveBytes);
	}

	// Step 4: Extract to cache/extracted/<name>@<version>/
	ensureDir(extractedPath);

	const zipR = openZip(archiveBytes);
	if (!zipR.ok) {
		console.log(`  error: invalid zip archive for ${name}@${version}`);
		return false;
	}
	const reader = zipR.value;
	const entries = zipEntries(reader);

	for (const entry of entries) {
		if (entry.isDir) continue;

		// Strip "package/" prefix from entry names
		let entryPath = entry.name;
		if (entryPath.length > 8 && entryPath.slice(0, 8) == "package/") {
			entryPath = entryPath.slice(8, entryPath.length);
		}

		// Skip manifest.json (internal, not needed in extracted form)
		if (entryPath == "manifest.json") continue;

		const outPath = join(extractedPath, entryPath);
		ensureDir(dirname(outPath));

		// Extract file content
		const idx = zipFindByName(reader, entry.name);
		if (idx < 0) continue;
		const contentR = zipExtract(reader, idx);
		if (!contentR.ok) {
			console.log(`  warning: failed to extract ${entryPath}`);
			continue;
		}
		writeFile(outPath, contentR.value);
		// Make read-only (0444)
		chmod(outPath, 292 as int32);
	}

	closeZip(reader);
	console.log(`  extracted ${name}@${version} (${entries.length.toString()} files)`);
	return true;
}
