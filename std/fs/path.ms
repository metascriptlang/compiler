// File System — Path Utilities (Pure MetaScript)
//
// Cross-platform path manipulation via string scanning.
// Accepts both `/` and `\` as separators on input; emits `/` on output.
// Recognizes POSIX root (`/`), Windows drive letters (`C:\`, `C:/`), and
// UNC paths (`\\server\share`, `//server/share`). No runtime OS detection.
// No C dependency — works on all backends.

// ===== Internal helpers =====

function isSepCode(c: number): boolean {
	return c === "/".code || c === "\\".code;
}

function isAlphaCode(c: number): boolean {
	return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code);
}

// True if p begins with "<letter>:" drive-letter prefix.
function hasDriveLetter(p: string): boolean {
	return p.length >= 2 && isAlphaCode(p.charCodeAt(0)) && p.charCodeAt(1) === ":".code;
}

// True if p begins with UNC "\\server" or "//server" prefix
// (two separators followed by a non-separator server name).
function hasUncPrefix(p: string): boolean {
	return p.length >= 3 && isSepCode(p.charCodeAt(0)) && isSepCode(p.charCodeAt(1)) && !isSepCode(p.charCodeAt(2));
}

// Length of the root prefix: 0 for relative, 1 for POSIX root,
// 2 for bare drive ("C:"), 3 for drive+sep ("C:/"), or length of
// "//server/share" for UNC. Returns 0 if not absolute.
function rootLen(p: string): number {
	if (p.length === 0) return 0;
	if (hasUncPrefix(p)) {
		let i = 2;
		while (i < p.length && !isSepCode(p.charCodeAt(i))) i = i + 1;
		if (i >= p.length) return i;
		i = i + 1;
		while (i < p.length && !isSepCode(p.charCodeAt(i))) i = i + 1;
		return i;
	}
	if (hasDriveLetter(p)) {
		if (p.length >= 3 && isSepCode(p.charCodeAt(2))) return 3;
		return 2;
	}
	if (isSepCode(p.charCodeAt(0))) return 1;
	return 0;
}

// Replace all "\" with "/" in p. Fast path when p has no "\".
function toForwardSlash(p: string): string {
	let i = 0;
	while (i < p.length) {
		if (p.charCodeAt(i) === "\\".code) break;
		i = i + 1;
	}
	if (i === p.length) return p;
	let result = p.slice(0, i);
	while (i < p.length) {
		const c = p.charCodeAt(i);
		if (c === "\\".code) {
			result = result + "/";
		} else {
			result = result + p.slice(i, i + 1);
		}
		i = i + 1;
	}
	return result;
}

// ===== dirname =====

// Return directory portion of path. Accepts both "/" and "\"; emits "/".
// "/a/b/c" → "/a/b", "/a" → "/", "file" → "."
// "C:\a\b" → "C:/a", "C:\a" → "C:/", "C:" → "C:"
// "\\s\d\x" → "//s/d"
export function dirname(p: string): string {
	if (p.length === 0) return ".";
	const rl = rootLen(p);
	let end = p.length;
	while (end > rl && isSepCode(p.charCodeAt(end - 1))) end = end - 1;
	let i = end - 1;
	while (i >= rl) {
		if (isSepCode(p.charCodeAt(i))) {
			if (rl >= 2 && hasDriveLetter(p) && i === 2) {
				return toForwardSlash(p.slice(0, 3));
			}
			if (i === 0) return "/";
			return toForwardSlash(p.slice(0, i));
		}
		i = i - 1;
	}
	if (rl > 0) return toForwardSlash(p.slice(0, rl));
	return ".";
}

// ===== basename =====

// Return file name portion of path. Accepts both "/" and "\".
// "/a/b/c.ms" → "c.ms", "/a/" → "", "file" → "file", "C:\a\b.ms" → "b.ms"
export function basename(p: string): string {
	if (p.length === 0) return "";
	let end = p.length;
	while (end > 0 && isSepCode(p.charCodeAt(end - 1))) end = end - 1;
	if (end === 0) return "";
	let i = end - 1;
	while (i >= 0) {
		if (isSepCode(p.charCodeAt(i))) {
			return p.slice(i + 1, end);
		}
		i = i - 1;
	}
	if (hasDriveLetter(p) && end >= 2) {
		return p.slice(2, end);
	}
	return p.slice(0, end);
}

// ===== extname =====

// Return file extension including dot. Accepts both "/" and "\".
// "foo.ms" → ".ms", "foo" → "", ".hidden" → "", "C:\a\b.tar.gz" → ".gz"
export function extname(p: string): string {
	let i = p.length - 1;
	while (i > 0) {
		if (p.charCodeAt(i) === ".".code) {
			if (i > 0 && !isSepCode(p.charCodeAt(i - 1))) {
				return p.slice(i, p.length);
			}
			return "";
		}
		if (isSepCode(p.charCodeAt(i))) return "";
		i = i - 1;
	}
	return "";
}

// ===== join =====

// Combine two path segments. Accepts "/" or "\" as separator on input.
// Emits "/" on output. Absolute b wins. Normalizes the result (collapses
// "./", "../", duplicate separators) — matches Node.js posix-join semantics.
export function join(a: string, b: string): string {
	if (b.length > 0 && isAbsolute(b)) return normalize(b);
	if (a.length === 0) return normalize(b);
	if (b.length === 0) return normalize(a);
	const aNorm = toForwardSlash(a);
	const bNorm = toForwardSlash(b);
	const joined = aNorm.charCodeAt(aNorm.length - 1) === "/".code
		? aNorm + bNorm
		: aNorm + "/" + bNorm;
	return normalize(joined);
}

// ===== resolve =====

// Resolve path against a base directory. Absolute paths pass through.
export function resolve(p: string, base: string): string {
	if (isAbsolute(p)) return toForwardSlash(p);
	return join(base, p);
}

// ===== isAbsolute =====

// True if p is absolute: POSIX ("/foo"), drive-letter ("C:", "C:/foo", "C:\foo"),
// or UNC ("//server/share", "\\server\share").
export function isAbsolute(p: string): boolean {
	if (p.length === 0) return false;
	if (isSepCode(p.charCodeAt(0))) return true;  // "/" or "\", POSIX or UNC
	if (hasDriveLetter(p)) return true;
	return false;
}

// ===== normalize =====

// Collapse "." and ".." segments; canonicalize separators to "/".
// Preserves root prefix: POSIX "/", drive "C:/", UNC "//server/share".
// "a/b/../c" → "a/c", "a/./b" → "a/b", "///a" → "/a"
// "C:\a\..\b" → "C:/b", "\\s\d\.\x" → "//s/d/x"
export function normalize(p: string): string {
	if (p.length === 0) return ".";
	const rl = rootLen(p);
	// Extract root prefix (normalized to forward-slash form)
	let prefix = "";
	if (rl > 0) {
		prefix = toForwardSlash(p.slice(0, rl));
		// Ensure drive prefix has trailing "/" for absolute; bare "C:" stays bare
		if (rl === 2 && hasDriveLetter(p)) {
			// "C:" without separator — stays relative to drive's cwd
		} else if (!isSepCode(prefix.charCodeAt(prefix.length - 1))) {
			// UNC "//server/share" or drive "C:/" already end correctly;
			// only case this matters is UNC where rl ends exactly at share name
			// (no trailing sep) — add one for parts joining
			prefix = prefix + "/";
		}
	}
	const rest = rl < p.length ? p.slice(rl, p.length) : "";
	const parts: string[] = [];
	const rootedForParts = rl > 0 && (rl !== 2 || !hasDriveLetter(p));
	let start = 0;
	let i = 0;
	while (i <= rest.length) {
		if (i === rest.length || isSepCode(rest.charCodeAt(i))) {
			if (i > start) {
				const seg = rest.slice(start, i);
				if (seg === "..") {
					if (parts.length > 0 && parts[parts.length - 1] !== "..") {
						parts.pop();
					} else if (!rootedForParts) {
						parts.push("..");
					}
				} else if (seg !== ".") {
					parts.push(seg);
				}
			}
			start = i + 1;
		}
		i = i + 1;
	}
	if (parts.length === 0) {
		if (rl > 0) {
			// Return root as-is (with or without trailing sep per drive/UNC rules)
			if (rl === 2 && hasDriveLetter(p)) return prefix;  // "C:"
			// Ensure single trailing slash for POSIX "/" and drive root "C:/"
			if (prefix.length >= 2 && prefix.charCodeAt(prefix.length - 1) === "/".code && prefix.charCodeAt(prefix.length - 2) === "/".code) {
				// UNC: "//server/share/" — strip trailing sep to "//server/share"
				return prefix.slice(0, prefix.length - 1);
			}
			if (prefix === "/") return "/";
			return prefix;
		}
		return ".";
	}
	let result = prefix;
	let j = 0;
	while (j < parts.length) {
		if (j > 0) result = result + "/";
		result = result + parts[j];
		j = j + 1;
	}
	return result;
}

// ===== Tests =====

test "dirname basic" {
	assert dirname("/a/b/c.ms") === "/a/b";
	assert dirname("/a/b.ms") === "/a";
	assert dirname("/a.ms") === "/";
}

test "dirname no slash" {
	assert dirname("file.ms") === ".";
}

test "dirname empty" {
	assert dirname("") === ".";
}

test "dirname root" {
	assert dirname("/") === "/";
}

test "basename basic" {
	assert basename("/a/b/c.ms") === "c.ms";
	assert basename("c.ms") === "c.ms";
}

test "basename trailing slash" {
	assert basename("/a/b/") === "b";
	assert basename("/a/b///") === "b";
}

test "basename empty" {
	assert basename("") === "";
}

test "extname basic" {
	assert extname("foo.ms") === ".ms";
	assert extname("/a/b/foo.tar.gz") === ".gz";
}

test "extname no ext" {
	assert extname("foo") === "";
	assert extname("/a/b/foo") === "";
}

test "extname hidden file" {
	assert extname(".hidden") === "";
}

test "join basic" {
	assert join("/a/b", "c.ms") === "/a/b/c.ms";
	assert join("/a/b/", "c.ms") === "/a/b/c.ms";
}

test "join absolute b wins" {
	assert join("/a", "/b/c") === "/b/c";
}

test "join empty a" {
	assert join("", "b") === "b";
}

test "resolve relative" {
	assert resolve("b.ms", "/a") === "/a/b.ms";
}

test "resolve absolute passthrough" {
	assert resolve("/b.ms", "/a") === "/b.ms";
}

test "isAbsolute basic" {
	assert isAbsolute("/a/b");
	assert !isAbsolute("a/b");
	assert !isAbsolute("");
}

test "normalize dot segments" {
	assert normalize("a/./b") === "a/b";
	assert normalize("a/b/../c") === "a/c";
}

test "normalize double dot at root" {
	assert normalize("/a/b/../../c") === "/c";
	assert normalize("/..") === "/";
}

test "normalize relative double dot" {
	assert normalize("../a") === "../a";
}

test "normalize empty" {
	assert normalize("") === ".";
}

test "normalize multiple slashes" {
	assert normalize("///a///b") === "/a/b";
}

// ===== Windows path tests =====

test "dirname Windows drive absolute" {
	assert dirname("C:\\foo\\bar.ms") === "C:/foo";
	assert dirname("C:/foo/bar.ms") === "C:/foo";
}

test "dirname Windows drive root" {
	assert dirname("C:\\foo") === "C:/";
	assert dirname("C:/foo") === "C:/";
}

test "dirname drive bare" {
	assert dirname("C:") === "C:";
}

test "dirname mixed separators" {
	assert dirname("C:/foo\\bar.ms") === "C:/foo";
	assert dirname("C:\\foo/bar.ms") === "C:/foo";
}

test "dirname UNC path" {
	assert dirname("\\\\server\\share\\dir\\file.ms") === "//server/share/dir";
}

test "basename Windows path" {
	assert basename("C:\\foo\\bar.ms") === "bar.ms";
	assert basename("C:/foo/bar.ms") === "bar.ms";
	assert basename("\\\\server\\share\\file.ms") === "file.ms";
}

test "basename drive bare" {
	assert basename("C:foo.ms") === "foo.ms";
}

test "extname Windows path" {
	assert extname("C:\\foo\\bar.ms") === ".ms";
	assert extname("C:\\foo\\bar.tar.gz") === ".gz";
	assert extname("C:\\foo\\Makefile") === "";
}

test "isAbsolute POSIX" {
	assert isAbsolute("/a/b");
	assert !isAbsolute("a/b");
	assert !isAbsolute("");
}

test "isAbsolute drive letter" {
	assert isAbsolute("C:/foo");
	assert isAbsolute("C:\\foo");
	assert isAbsolute("C:");
	assert isAbsolute("z:/lower");
	assert !isAbsolute("Cfoo");
	assert !isAbsolute("1:/numeric");
}

test "isAbsolute UNC" {
	assert isAbsolute("//server/share");
	assert isAbsolute("\\\\server\\share");
}

test "join mixed separators" {
	assert join("C:\\foo", "bar") === "C:/foo/bar";
	assert join("C:/foo/", "bar") === "C:/foo/bar";
	assert join("/a\\b", "c") === "/a/b/c";
}

test "join Windows absolute b wins" {
	assert join("/a", "C:\\b") === "C:/b";
	assert join("/a", "\\\\server\\share") === "//server/share";
}

test "resolve Windows absolute passthrough" {
	assert resolve("C:\\foo", "/base") === "C:/foo";
	assert resolve("foo", "C:\\base") === "C:/base/foo";
}

test "normalize Windows drive" {
	assert normalize("C:\\foo\\.\\bar") === "C:/foo/bar";
	assert normalize("C:/foo/../bar") === "C:/bar";
}

test "normalize Windows mixed" {
	assert normalize("C:\\a/b\\..\\c") === "C:/a/c";
}

test "normalize UNC" {
	assert normalize("\\\\s\\d\\.\\x") === "//s/d/x";
	assert normalize("//server/share/a/../b") === "//server/share/b";
}
