import { sha256 } from "std/crypto";

export struct ManifestEntry {
	path: string;
	digest: string;
}

function isDigest(text: string): boolean {
	if (text.length != 64) { return false; }
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		if ((code < 48 || code > 57) && (code < 97 || code > 102)) {
			return false;
		}
	}
	return true;
}

function isSafePath(path: string): boolean {
	if (path == "" || path.startsWith("/")) { return false; }
	if (path.indexOf("\\") >= 0 || path.indexOf("\0") >= 0 ||
		path.indexOf("\n") >= 0 || path.indexOf("\r") >= 0) {
		return false;
	}
	if (path.length >= 2 && path.charCodeAt(1) == 58) {
		const first = path.charCodeAt(0);
		if ((first >= 65 && first <= 90) ||
			(first >= 97 && first <= 122)) {
			return false;
		}
	}
	for (const part of path.split("/")) {
		if (part == "" || part == "." || part == "..") { return false; }
	}
	return path != "FILES.sha256" && path != "IDENTITY";
}

function orderedBefore(left: string, right: string): boolean {
	const a = left.asBytes();
	const b = right.asBytes();
	const count = a.length < b.length ? a.length : b.length;
	for (let i: int64 = 0; i < count; i += 1) {
		if (a[i] != b[i]) { return a[i] < b[i]; }
	}
	return a.length < b.length;
}

export function renderManifest(
	entries: ManifestEntry[],
): Result<string, string> {
	let text = "";
	let previous = "";
	for (const entry of entries) {
		if (!isDigest(entry.digest)) {
			return Result.err("FILES.sha256: bad digest: " + entry.path);
		}
		if (!isSafePath(entry.path)) {
			return Result.err("FILES.sha256: unsafe path: " + entry.path);
		}
		if (previous != "" && !orderedBefore(previous, entry.path)) {
			return Result.err("FILES.sha256: paths are not unique and sorted");
		}
		text += entry.digest + "  " + entry.path + "\n";
		previous = entry.path;
	}
	return Result.ok(text);
}

export function parseManifest(text: string): Result<ManifestEntry[], string> {
	const entries: ManifestEntry[] = [];
	if (text == "") { return Result.ok(entries); }
	if (!text.endsWith("\n")) {
		return Result.err("FILES.sha256: missing final LF");
	}
	const lines = text.split("\n");
	for (let i: int32 = 0; i + 1 < lines.length; i += 1) {
		const line = lines[i];
		if (line.length < 67 || line.slice(64, 66) != "  ") {
			return Result.err("FILES.sha256: bad line " + String(i + 1));
		}
		entries.push({
			digest: line.slice(0, 64),
			path: line.slice(66, line.length),
		});
	}
	const rendered = renderManifest(entries);
	if (!rendered.ok) { return Result.err(rendered.error); }
	return Result.ok(entries);
}

export struct ContractHeader {
	host: string;
	version: string;
}

function oneLine(text: string): boolean {
	return text.endsWith("\n") && text.indexOf("\n") == text.length - 1;
}

export function parseHeader(
	hostLine: string,
	versionLine: string,
): Result<ContractHeader, string> {
	if (!oneLine(hostLine)) { return Result.err("HOST is not one line"); }
	const host = hostLine.slice(0, hostLine.length - 1);
	let known = false;
	for (const candidate of [
		"aarch64-macos", "x86_64-macos", "x86_64-linux", "aarch64-linux",
		"x86_64-windows", "aarch64-windows",
	]) {
		if (host == candidate) { known = true; }
	}
	if (!known) { return Result.err("HOST is not a supported engine host"); }
	if (!oneLine(versionLine)) {
		return Result.err("VERSION is not one line");
	}
	const version = versionLine.slice(0, versionLine.length - 1);
	const parts = version.split(".");
	if (parts.length != 3) {
		return Result.err("VERSION must contain three decimal components");
	}
	for (const part of parts) {
		if (part == "") { return Result.err("VERSION has an empty component"); }
		for (let i: int32 = 0; i < part.length; i += 1) {
			const code = part.charCodeAt(i);
			if (code < 48 || code > 57) {
				return Result.err("VERSION has a non-decimal component");
			}
		}
	}
	return Result.ok({ host, version });
}

export function manifestIdentity(text: string): Result<string, string> {
	const digest = sha256(text);
	if (!digest.ok) { return Result.err(digest.error.message); }
	return Result.ok(digest.value + "\n");
}

export function verifyIdentity(
	text: string,
	identityLine: string,
): Result<void, string> {
	if (!oneLine(identityLine) ||
		!isDigest(identityLine.slice(0, identityLine.length - 1))) {
		return Result.err("IDENTITY is not one lowercase SHA-256 line");
	}
	const expected = manifestIdentity(text);
	if (!expected.ok) { return Result.err(expected.error); }
	if (identityLine != expected.value) {
		return Result.err("IDENTITY does not match FILES.sha256");
	}
	return Result.ok(null);
}
