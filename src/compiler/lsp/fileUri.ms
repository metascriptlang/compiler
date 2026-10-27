import { digitValue } from "std/core/number/parse";

function escapedByte(s: string, at: int32): int32 {
	if (at + 2 >= s.length || s.charAt(at) != "%") return -1;
	const hi = digitValue(s.charCodeAt(at + 1));
	const lo = digitValue(s.charCodeAt(at + 2));
	return hi < 16 && lo < 16 ? hi * 16 + lo : -1;
}

function continuationEscape(s: string, at: int32): int32 {
	const b = escapedByte(s, at);
	return b >= 0x80 && b < 0xC0 ? b - 0x80 : -1;
}

// The code point of the UTF-8 escape run at `at`, or -1 when it is not a well-formed run.
function escapedCodePoint(s: string, at: int32): int32 {
	const b0 = escapedByte(s, at);
	if (b0 < 0x80) return b0;
	const need = b0 >= 0xF0 ? 3 : b0 >= 0xE0 ? 2 : b0 >= 0xC2 ? 1 : 0;
	if (need == 0 || b0 > 0xF4) return -1;
	let cp = b0 - (need == 3 ? 0xF0 : need == 2 ? 0xE0 : 0xC0);
	for (let k = 1; k <= need; k++) {
		const cb = continuationEscape(s, at + 3 * k);
		if (cb < 0) return -1;
		cp = cp * 64 + cb;
	}
	const floor = need == 3 ? 0x10000 : need == 2 ? 0x800 : 0x80;
	const surrogate = cp >= 0xD800 && cp <= 0xDFFF;
	return cp < floor || cp > 0x10FFFF || surrogate ? -1 : cp;
}

function lspPercentDecode(s: string): string {
	let out = "";
	let i = 0;
	while (i < s.length) {
		const cp = escapedCodePoint(s, i);
		if (cp < 0) {
			out += s.charAt(i);
			i++;
			continue;
		}
		out += fromCodePoint(cp);
		i += cp < 0x80 ? 3 : cp < 0x800 ? 6 : cp < 0x10000 ? 9 : 12;
	}
	return out;
}

export function lspUriToPath(uri: string): string {
	const prefix = "file://";
	if (uri.byteLength > prefix.byteLength) {
		if (uri.slice(0, prefix.byteLength) == prefix) {
			const stripped = lspPercentDecode(uri.slice(prefix.byteLength, uri.byteLength));
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

test "uri to path keeps an invalid utf-8 escape run literally" {
	assert lspUriToPath("file:///a/%80b.ms") == "/a/%80b.ms";
	assert lspUriToPath("file:///a/%C3%41.ms") == "/a/%C3A.ms";
	assert lspUriToPath("file:///a/%C3") == "/a/%C3";
	assert lspUriToPath("file:///a/%FF.ms") == "/a/%FF.ms";
	assert lspUriToPath("file:///a/%C0%80.ms") == "/a/%C0%80.ms";
	assert lspUriToPath("file:///a/%ED%A0%80.ms") == "/a/%ED%A0%80.ms";
}

test "uri to path decodes three and four byte escape runs" {
	assert lspUriToPath("file:///a/%E2%82%AC.ms") == "/a/" + fromCodePoint(0x20AC) + ".ms";
	assert lspUriToPath("file:///a/%F0%9F%98%80.ms") == "/a/" + fromCodePoint(0x1F600) + ".ms";
}
