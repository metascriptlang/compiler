// File System — Path Utilities (Pure MetaScript)
//
// POSIX path manipulation via string scanning.
// No C dependency — works on all backends.

// ===== dirname =====

// Return directory portion of path.
// "/a/b/c" → "/a/b", "/a" → "/", "file" → "."
export function dirname(p: string): string {
	if (p.length === 0) return ".";
	let i = p.length - 1;
	while (i >= 0) {
		if (p.charCodeAt(i) === "/".code) {
			if (i === 0) return "/";
			return p.slice(0, i);
		}
		i = i - 1;
	}
	return ".";
}

// ===== basename =====

// Return file name portion of path.
// "/a/b/c.ms" → "c.ms", "/a/" → "", "file" → "file"
export function basename(p: string): string {
	if (p.length === 0) return "";
	let i = p.length - 1;
	while (i >= 0) {
		if (p.charCodeAt(i) === "/".code) {
			return p.slice(i + 1, p.length);
		}
		i = i - 1;
	}
	return p;
}

// ===== extname =====

// Return file extension including dot.
// "foo.ms" → ".ms", "foo" → "", ".hidden" → ""
export function extname(p: string): string {
	let i = p.length - 1;
	while (i > 0) {
		if (p.charCodeAt(i) === ".".code) {
			// Don't count leading dot as extension (e.g. ".hidden")
			if (i > 0 && p.charCodeAt(i - 1) !== "/".code) {
				return p.slice(i, p.length);
			}
			return "";
		}
		if (p.charCodeAt(i) === "/".code) return "";
		i = i - 1;
	}
	return "";
}

// ===== join =====

// Combine two path segments.
// Absolute b wins. Trailing slash on a avoids double slash.
export function join(a: string, b: string): string {
	if (b.length > 0 && b.charCodeAt(0) === "/".code) return b;
	if (a.length === 0) return b;
	if (a.charCodeAt(a.length - 1) === "/".code) return a + b;
	return a + "/" + b;
}

// ===== resolve =====

// Resolve path against a base directory.
// Absolute paths pass through unchanged.
export function resolve(p: string, base: string): string {
	if (p.length > 0 && p.charCodeAt(0) === "/".code) return p;
	return join(base, p);
}

// ===== isAbsolute =====

export function isAbsolute(p: string): boolean {
	return p.length > 0 && p.charCodeAt(0) === "/".code;
}

// ===== normalize =====

// Collapse "." and ".." segments. Does not resolve symlinks.
// "a/b/../c" → "a/c", "a/./b" → "a/b", "///a" → "/a"
export function normalize(p: string): string {
	if (p.length === 0) return ".";
	const isAbs = p.charCodeAt(0) === "/".code;

	// Split into segments
	const parts: string[] = [];
	let start = 0;
	let i = 0;
	while (i <= p.length) {
		if (i === p.length || p.charCodeAt(i) === "/".code) {
			if (i > start) {
				const seg = p.slice(start, i);
				if (seg === "..") {
					if (parts.length > 0 && parts[parts.length - 1] !== "..") {
						parts.pop();
					} else if (!isAbs) {
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
		if (isAbs) return "/";
		return ".";
	}

	let result = "";
	if (isAbs) result = "/";
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
	assert basename("/a/b/") === "";
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
