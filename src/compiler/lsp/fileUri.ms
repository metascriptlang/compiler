// File URIs: percent-encoding between LSP document URIs and filesystem paths.

import { digitValue } from "std/core/number/parse";

function escapedByte(s: string, at: int32): int32 {
	if (at + 2 >= s.length || s.charAt(at) != "%") return -1;
	const hi = digitValue(s.charCodeAt(at + 1));
	const lo = digitValue(s.charCodeAt(at + 2));
	return hi < 16 && lo < 16 ? hi * 16 + lo : -1;
}

// Percent-decoding. Real clients hand us escaped URIs: the VS Code plugin sends
// `document.uri.toString()`, which escapes the Windows drive colon as `%3A` and
// every space as `%20`. Left undecoded, the drive-letter check below never fires
// and every path-keyed feature (project root, build.ms lookup) silently resolves
// against a path that exists nowhere.
//
// Escapes are UTF-8 BYTES, so a non-ASCII character arrives as a run of them
// (é = %C3%A9); decoding each byte through fromCodePoint would emit mojibake.
// Continuation bytes are folded into one code point here.
function lspPercentDecode(s: string): string {
	let out = "";
	let i = 0;
	while (i < s.length) {
		const b0 = escapedByte(s, i);
		if (b0 < 0) {
			out += s.charAt(i);
			i++;
			continue;
		}
		i += 3;
		if (b0 < 0x80) {
			out += fromCodePoint(b0);
			continue;
		}
		const need = b0 >= 0xF0 ? 3 : b0 >= 0xE0 ? 2 : b0 >= 0xC0 ? 1 : 0;
		if (need == 0) continue;
		let cp = b0 - (need == 3 ? 0xF0 : need == 2 ? 0xE0 : 0xC0);
		let ok = true;
		for (let taken = 0; taken < need; taken++) {
			const cb = escapedByte(s, i);
			if (cb < 0x80 || cb >= 0xC0) { ok = false; break; }
			cp = cp * 64 + (cb - 0x80);
			i += 3;
		}
		if (ok) out += fromCodePoint(cp);
	}
	return out;
}

export function lspUriToPath(uri: string): string {
	// "file:///Users/foo/bar.ms" → "/Users/foo/bar.ms"
	// "file:///C:/Users/foo.ms" → "C:/Users/foo.ms" (drop leading slash before drive)
	const prefix = "file://";
	if (uri.byteLength > prefix.byteLength) {
		if (uri.slice(0, prefix.byteLength) == prefix) {
			const stripped = lspPercentDecode(uri.slice(prefix.byteLength, uri.byteLength));
			// Windows: "/C:/..." → "C:/..." (RFC 8089 file URIs)
			if (stripped.length >= 3 && stripped.charAt(0) == "/" && stripped.charAt(2) == ":") {
				return stripped.slice(1, stripped.length);
			}
			return stripped;
		}
	}
	return uri;
}

export function lspPathToUri(path: string): string {
	const drive = path.length >= 2 && path.charAt(1) == ":" ? path.charAt(0).toLowerCase() : "";
	if (drive != "" && "abcdefghijklmnopqrstuvwxyz".includes(drive)) return `file:///${drive}%3A${lspPathEscape(path.slice(2, path.length))}`;
	return "file://" + lspPathEscape(path);
}

function lspPathEscape(path: string): string {
	const hex = "0123456789ABCDEF";
	let out = "";
	for (let i = 0; i < path.byteLength; i++) {
		const b = path.byteAt(i);
		const kept = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
			|| b == "-".code || b == ".".code || b == "_".code || b == "~".code || b == "/".code;
		out = kept ? out + fromCodePoint(b) : `${out}%${hex.charAt(b >> 4)}${hex.charAt(b & 15)}`;
	}
	return out;
}

test "uri to path" { assert lspUriToPath("file:///Users/foo/bar.ms") == "/Users/foo/bar.ms"; }

test "path to uri" { assert lspPathToUri("/a/b.ms") == "file:///a/b.ms"; }

test "path to uri gives a windows drive as the escaped lower-case volume a client sends" {
	assert lspPathToUri("C:/Users/foo/bar.ms") == "file:///c%3A/Users/foo/bar.ms";
	assert lspPathToUri("d:/x.ms") == "file:///d%3A/x.ms";
	assert lspUriToPath(lspPathToUri("C:/x/y.ms")) == "c:/x/y.ms";
}

test "path to uri escapes every byte of a segment outside the unreserved set" {
	assert lspPathToUri("/My Docs/a#1?b.ms") == "file:///My%20Docs/a%231%3Fb.ms";
	assert lspPathToUri("C:/a b/[x]@y.ms") == "file:///c%3A/a%20b/%5Bx%5D%40y.ms";
	assert lspPathToUri("/Users/caf" + fromCodePoint(233) + "/a-b_c.~ms") == "file:///Users/caf%C3%A9/a-b_c.~ms";
	const odd = "/q/a b#c%d/e.ms";
	assert lspUriToPath(lspPathToUri(odd)) == odd;
}

test "non-file uri unchanged" { assert lspUriToPath("http://example.com") == "http://example.com"; }

test "uri to path decodes the escaped windows drive colon" {
	// What the VS Code plugin actually sends on Windows (vscode-uri toString).
	assert lspUriToPath("file:///c%3A/Users/foo/bar.ms") == "c:/Users/foo/bar.ms";
	assert lspUriToPath("file:///C%3A/Users/foo/bar.ms") == "C:/Users/foo/bar.ms";
}

test "uri to path decodes escaped spaces" {
	assert lspUriToPath("file:///Users/My%20Docs/a.ms") == "/Users/My Docs/a.ms";
}

test "uri to path leaves an unescaped uri unchanged" {
	assert lspUriToPath("file:///C:/x/y.ms") == "C:/x/y.ms";
	assert lspUriToPath("file:///Users/foo/bar.ms") == "/Users/foo/bar.ms";
}

test "uri to path folds multi-byte utf-8 escapes into one code point" {
	// caf%C3%A9 is two escapes for ONE character; byte-wise decoding would
	// yield mojibake and a path that opens nothing.
	const p = lspUriToPath("file:///Users/caf%C3%A9/a.ms");
	assert p == "/Users/caf" + fromCodePoint(233) + "/a.ms";
}

test "uri to path keeps a literal percent that is not an escape" {
	assert lspUriToPath("file:///Users/100%pure/a.ms") == "/Users/100%pure/a.ms";
	assert lspUriToPath("file:///Users/a%zz/b.ms") == "/Users/a%zz/b.ms";
}
