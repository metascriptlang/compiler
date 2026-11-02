import { sha256 } from "std/crypto";

const DIGEST_LENGTH: int32 = 64;
const SEPARATOR = "  ";
const ENGINE_HOSTS = [
	"aarch64-macos",
	"x86_64-macos",
	"x86_64-linux",
	"aarch64-linux",
	"x86_64-windows",
	"aarch64-windows",
];

export struct ManifestEntry {
	path: string;
	digest: string;
}

function isDigest(text: string): boolean {
	if (text.length != DIGEST_LENGTH) { return false; }
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		const decimal = code >= "0".code && code <= "9".code;
		const lowerHex = code >= "a".code && code <= "f".code;
		if (!decimal && !lowerHex) { return false; }
	}
	return true;
}

function startsWithDriveLetter(path: string): boolean {
	if (path.length < 2 || path.charCodeAt(1) != ":".code) { return false; }
	const first = path.charCodeAt(0);
	return (first >= "A".code && first <= "Z".code) ||
		(first >= "a".code && first <= "z".code);
}

function isSafePath(path: string): boolean {
	if (path == "" || path.startsWith("/")) { return false; }
	if (path.indexOf("\\") >= 0 || path.indexOf("\0") >= 0 ||
		path.indexOf("\n") >= 0 || path.indexOf("\r") >= 0) {
		return false;
	}
	if (startsWithDriveLetter(path)) { return false; }
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
		text += entry.digest + SEPARATOR + entry.path + "\n";
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
	const pathStart = DIGEST_LENGTH + SEPARATOR.length;
	const lines = text.split("\n");
	for (let i: int32 = 0; i + 1 < lines.length; i += 1) {
		const line = lines[i];
		if (line.length <= pathStart ||
			line.slice(DIGEST_LENGTH, pathStart) != SEPARATOR) {
			return Result.err("FILES.sha256: bad line " + String(i + 1));
		}
		entries.push({
			digest: line.slice(0, DIGEST_LENGTH),
			path: line.slice(pathStart, line.length),
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

function isEngineHost(host: string): boolean {
	for (const candidate of ENGINE_HOSTS) {
		if (host == candidate) { return true; }
	}
	return false;
}

function isDecimal(text: string): boolean {
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		if (code < "0".code || code > "9".code) { return false; }
	}
	return true;
}

export function parseHeader(
	hostLine: string,
	versionLine: string,
): Result<ContractHeader, string> {
	if (!oneLine(hostLine)) { return Result.err("HOST is not one line"); }
	const host = hostLine.slice(0, hostLine.length - 1);
	if (!isEngineHost(host)) {
		return Result.err("HOST is not a supported engine host");
	}
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
		if (!isDecimal(part)) {
			return Result.err("VERSION has a non-decimal component");
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
