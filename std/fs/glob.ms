// std/glob — gitignore-compatible glob matching
//
// Syntax (subset of gitignore / go:embed):
//   *          matches any number of non-slash characters
//   **         matches any number of path segments (must be a full segment)
//   ?          matches exactly one non-slash character
//   [abc]      character class (matches any of a, b, c)
//   [!abc]     negated character class
//   [a-z]      character range
//   /foo       leading slash anchors the pattern to the root
//   foo/       trailing slash is rewritten to foo/** (directory match)
//   foo        no slash anywhere → floating (matches at any depth)
//   foo/bar    internal slash → anchored to root
//
// Paths are expected to use forward slashes ("/") regardless of platform.
// Callers on Windows must normalize before matching.

// A compiled glob pattern. `segments` is the list of "/"-separated segments,
// possibly with a leading "**" to indicate a floating (non-anchored) pattern.
export interface Glob {
	segments: string[];
}

// Compile a glob pattern into a matcher. Returns an error message if the
// pattern is syntactically invalid (e.g. empty, unterminated character class).
export function compileGlob(pattern: string): Result<Glob, string> {
	if (pattern.length === 0) return Result.err("empty pattern");

	let p = pattern;

	// Leading slash → explicit anchor (strip the slash, remember).
	let anchored = false;
	if (p.charAt(0) === "/") {
		anchored = true;
		p = p.slice(1, p.length);
	}

	// Trailing slash → directory match, rewrite to "...foo/**".
	if (p.length > 0 && p.charAt(p.length - 1) === "/") {
		p = p + "**";
	}

	// Validate character classes are balanced (cheap early check).
	let i = 0;
	while (i < p.length) {
		if (p.charAt(i) === "[") {
			let end = i + 1;
			while (end < p.length && p.charAt(end) !== "]") end = end + 1;
			if (end >= p.length) return Result.err("unterminated character class in: " + pattern);
			i = end + 1;
		} else {
			i = i + 1;
		}
	}

	// Split on "/" into segments.
	const rawSegs = p.split("/");

	// Reject "a**" or "**b" — "**" must be a FULL segment on its own.
	for (const seg of rawSegs) {
		let k = 0;
		while (k < seg.length - 1) {
			if (seg.charAt(k) === "*" && seg.charAt(k + 1) === "*") {
				if (seg !== "**") {
					return Result.err("'**' must be a full path segment in: " + pattern);
				}
				k = k + 2;
			} else {
				k = k + 1;
			}
		}
	}

	// Collapse relative-path segments uniformly. Matches Bun's GlobWalker
	// semantics (src/glob/GlobWalker.zig:1434-1443 — .Dot / .DotBack syntax
	// hints): "." is a no-op segment (skip without consuming path input);
	// ".." is rejected because publish globs must not escape the project
	// root. A leading "." additionally anchors the pattern at the root,
	// the standard Unix spelling of "foo in current directory".
	const segs: string[] = [];
	for (let k = 0; k < rawSegs.length; k = k + 1) {
		const seg = rawSegs[k];
		if (seg === ".") {
			if (segs.length === 0) anchored = true;
			continue;
		}
		if (seg === "..") {
			return Result.err("'..' is not allowed in pattern: " + pattern);
		}
		segs.push(seg);
	}
	if (segs.length === 0) {
		return Result.err("pattern collapses to empty: " + pattern);
	}

	// Has-internal-slash → also anchored. Floating patterns prepend "**".
	const hasSlash = segs.length > 1;
	if (!anchored && !hasSlash) {
		// No slash anywhere → floating. Prepend "**".
		const withFloat: string[] = ["**"];
		let k = 0;
		while (k < segs.length) { withFloat.push(segs[k]); k = k + 1; }
		return Result.ok({ segments: withFloat });
	}

	return Result.ok({ segments: segs });
}

// Compile a list of patterns. Invalid patterns are dropped with their error
// returned in `errors` — caller decides whether to fail or warn.
export interface CompiledGlobs {
	globs: Glob[];
	errors: string[];
}

export function compileGlobs(patterns: string[]): CompiledGlobs {
	const globs: Glob[] = [];
	const errors: string[] = [];
	for (const pat of patterns) {
		const r = compileGlob(pat);
		if (r.ok) {
			globs.push(r.value);
		} else {
			errors.push(r.error);
		}
	}
	return { globs, errors };
}

// Match a compiled glob against a path (forward slashes, no leading /).
export function globMatch(g: Glob, path: string): boolean {
	const pathSegs = path.split("/");
	return matchSegments(g.segments, 0, pathSegs, 0);
}

// Match against any compiled glob. Returns true if at least one matches.
export function globMatchAny(gs: Glob[], path: string): boolean {
	for (const g of gs) {
		if (globMatch(g, path)) return true;
	}
	return false;
}

// --- Internal: segment-level recursive matcher ---

function matchSegments(pats: string[], pi: number, paths: string[], si: number): boolean {
	while (pi < pats.length) {
		const pat = pats[pi];
		if (pat === "**") {
			// Trailing "**" matches any remaining segments (including zero).
			if (pi + 1 === pats.length) return true;
			// Try consuming 0, 1, 2, ... path segments and continue matching the rest.
			let k = si;
			while (k <= paths.length) {
				if (matchSegments(pats, pi + 1, paths, k)) return true;
				k = k + 1;
			}
			return false;
		}
		if (si >= paths.length) return false;
		if (!segMatch(pat, paths[si])) return false;
		pi = pi + 1;
		si = si + 1;
	}
	return si === paths.length;
}

// Match a single pattern segment against a single path component.
// Handles *, ?, and character classes. No slash-crossing.
function segMatch(pat: string, s: string): boolean {
	return segMatchAt(pat, 0, s, 0);
}

function segMatchAt(pat: string, piIn: number, s: string, siIn: number): boolean {
	let pi = piIn;
	let si = siIn;
	while (pi < pat.length) {
		const pc = pat.charAt(pi);
		if (pc === "*") {
			// Collapse consecutive stars.
			while (pi < pat.length && pat.charAt(pi) === "*") pi = pi + 1;
			if (pi === pat.length) return true; // trailing * matches rest
			// Try matching the remaining pattern at each position of s.
			let k = si;
			while (k <= s.length) {
				if (segMatchAt(pat, pi, s, k)) return true;
				k = k + 1;
			}
			return false;
		}
		if (pc === "?") {
			if (si >= s.length) return false;
			pi = pi + 1;
			si = si + 1;
			continue;
		}
		if (pc === "[") {
			if (si >= s.length) return false;
			// Parse the class.
			let end = pi + 1;
			let negate = false;
			if (end < pat.length && pat.charAt(end) === "!") { negate = true; end = end + 1; }
			const classStart = end;
			while (end < pat.length && pat.charAt(end) !== "]") end = end + 1;
			if (end >= pat.length) return false; // unterminated (shouldn't happen — compileGlob checks)
			const ch = s.charAt(si);
			let inClass = false;
			let k = classStart;
			while (k < end) {
				if (k + 2 < end && pat.charAt(k + 1) === "-") {
					// Range a-z
					const lo = pat.charAt(k);
					const hi = pat.charAt(k + 2);
					if (ch >= lo && ch <= hi) inClass = true;
					k = k + 3;
				} else {
					if (pat.charAt(k) === ch) inClass = true;
					k = k + 1;
				}
			}
			if (inClass === negate) return false;
			pi = end + 1;
			si = si + 1;
			continue;
		}
		// Literal character.
		if (si >= s.length) return false;
		if (s.charAt(si) !== pc) return false;
		pi = pi + 1;
		si = si + 1;
	}
	return si === s.length;
}

// ===== Tests =====

function mustCompile(p: string): Glob {
	const r = compileGlob(p);
	if (!r.ok) unreachable;
	return r.value;
}

test "compile rejects empty pattern" {
	const r = compileGlob("");
	assert !r.ok;
}

test "compile rejects partial **" {
	assert !compileGlob("a**b").ok;
	assert !compileGlob("**b").ok;
	assert !compileGlob("a**").ok;
}

test "compile accepts full-segment **" {
	assert compileGlob("**").ok;
	assert compileGlob("**/foo").ok;
	assert compileGlob("foo/**").ok;
	assert compileGlob("foo/**/bar").ok;
}

test "leading ./ is treated as root-anchored" {
	// "./foo" should match root-level "foo" (same as "/foo"), not deep "foo".
	assert globMatch(mustCompile("./foo"), "foo");
	assert !globMatch(mustCompile("./foo"), "bar/foo");
}

test "leading ./**/ matches full tree" {
	assert globMatch(mustCompile("./events/**/*.ms"), "events/apigw-v2.ms");
	assert globMatch(mustCompile("./events/**/*.ms"), "events/nested/inner.ms");
	assert !globMatch(mustCompile("./events/**/*.ms"), "other/foo.ms");
}

test "leading ./*.ms matches top-level only" {
	assert globMatch(mustCompile("./*.ms"), "build.ms");
	assert globMatch(mustCompile("./*.ms"), "index.ms");
	assert !globMatch(mustCompile("./*.ms"), "events/apigw-v2.ms");
}

test "middle . is no-op" {
	assert globMatch(mustCompile("foo/./bar.ms"), "foo/bar.ms");
	assert globMatch(mustCompile("events/./*.ms"), "events/apigw-v2.ms");
}

test "compile rejects .." {
	assert !compileGlob("../foo").ok;
	assert !compileGlob("foo/../bar").ok;
}

test "compile rejects bare . alone" {
	assert !compileGlob(".").ok;
}

test "compile rejects unterminated class" {
	assert !compileGlob("[abc").ok;
}

test "floating literal matches at any depth" {
	const g = mustCompile("README.md");
	assert globMatch(g, "README.md");
	assert globMatch(g, "src/README.md");
	assert globMatch(g, "deep/nested/README.md");
	assert !globMatch(g, "README.txt");
	assert !globMatch(g, "src/readme.md"); // case-sensitive
}

test "anchored leading slash" {
	const g = mustCompile("/README.md");
	assert globMatch(g, "README.md");
	assert !globMatch(g, "src/README.md");
}

test "star wildcard single segment" {
	const g = mustCompile("*.ms");
	assert globMatch(g, "main.ms");
	assert globMatch(g, "src/main.ms"); // floating
	assert !globMatch(g, "main.cms");
}

test "star does not cross slash" {
	const g = mustCompile("src/*.ms");
	assert globMatch(g, "src/main.ms");
	assert !globMatch(g, "src/sub/main.ms"); // "*" cannot consume "sub/"
}

test "double-star crosses slashes" {
	const g = mustCompile("src/**/*.ms");
	assert globMatch(g, "src/main.ms");        // ** consumes zero segments
	assert globMatch(g, "src/a/main.ms");
	assert globMatch(g, "src/a/b/c/main.ms");
	assert !globMatch(g, "other/main.ms");
}

test "trailing slash → directory match" {
	const g = mustCompile("out/");
	assert globMatch(g, "out");              // the dir itself
	assert globMatch(g, "out/foo.txt");
	assert globMatch(g, "out/sub/deep.txt");
	assert !globMatch(g, "outside/file.txt");
}

test "question mark single char" {
	const g = mustCompile("file?.ms");
	assert globMatch(g, "file1.ms");
	assert globMatch(g, "fileA.ms");
	assert !globMatch(g, "file.ms");
	assert !globMatch(g, "file12.ms");
}

test "char class" {
	const g = mustCompile("file[abc].ms");
	assert globMatch(g, "filea.ms");
	assert globMatch(g, "fileb.ms");
	assert globMatch(g, "filec.ms");
	assert !globMatch(g, "filed.ms");
}

test "negated char class" {
	const g = mustCompile("file[!abc].ms");
	assert !globMatch(g, "filea.ms");
	assert globMatch(g, "filed.ms");
	assert globMatch(g, "file9.ms");
}

test "char range" {
	const g = mustCompile("file[0-9].ms");
	assert globMatch(g, "file0.ms");
	assert globMatch(g, "file5.ms");
	assert globMatch(g, "file9.ms");
	assert !globMatch(g, "filea.ms");
}

test "double-star floating" {
	const g = mustCompile("**/test_*.ms");
	assert globMatch(g, "test_foo.ms");
	assert globMatch(g, "src/test_foo.ms");
	assert globMatch(g, "src/deep/nested/test_foo.ms");
	assert !globMatch(g, "src/foo.ms");
}

test "leading double-star" {
	const g = mustCompile("**/*.DS_Store");
	assert globMatch(g, ".DS_Store");
	assert globMatch(g, "src/.DS_Store");
	assert globMatch(g, "deep/nested/.DS_Store");
}

test "entire tree exclude" {
	// .git/** should match .git itself (as a dir to skip) AND any path inside
	const g = mustCompile(".git/**");
	assert globMatch(g, ".git");
	assert globMatch(g, ".git/HEAD");
	assert globMatch(g, ".git/refs/heads/main");
}

test "node_modules exclude" {
	const g = mustCompile("node_modules/**");
	assert globMatch(g, "node_modules");
	assert globMatch(g, "node_modules/foo/index.js");
	assert !globMatch(g, "src/foo.ms");
}

test "env file exclusions" {
	const g1 = mustCompile(".env");
	const g2 = mustCompile(".env.*");
	assert globMatch(g1, ".env");
	assert !globMatch(g1, ".env.local");
	assert globMatch(g2, ".env.local");
	assert globMatch(g2, ".env.production");
	assert !globMatch(g2, ".env");
}

test "log files floating" {
	const g = mustCompile("**/*.log");
	assert globMatch(g, "out.log");
	assert globMatch(g, "logs/error.log");
	assert globMatch(g, "src/deep/nested/warning.log");
	assert !globMatch(g, "out.txt");
}

test "matchesAny" {
	const gs = compileGlobs([".git/**", "out/**", "node_modules/**"]).globs;
	assert globMatchAny(gs, ".git/HEAD");
	assert globMatchAny(gs, "out/main.c");
	assert globMatchAny(gs, "node_modules/foo");
	assert !globMatchAny(gs, "src/main.ms");
}

test "anchored vs floating distinction" {
	const anchored = mustCompile("/src/main.ms");
	const floating = mustCompile("src/main.ms"); // has slash → also anchored
	const floatingNoSlash = mustCompile("main.ms"); // no slash → floating
	assert globMatch(anchored, "src/main.ms");
	assert !globMatch(anchored, "pkg/src/main.ms");
	assert globMatch(floating, "src/main.ms");
	assert !globMatch(floating, "pkg/src/main.ms");
	assert globMatch(floatingNoSlash, "main.ms");
	assert globMatch(floatingNoSlash, "pkg/src/main.ms"); // floats to any depth
}

test "star matches empty" {
	const g = mustCompile("*.ms");
	// A file literally named ".ms" — edge case, star matches zero chars before "."
	assert globMatch(g, ".ms");
}

test "compileGlobs collects errors" {
	const result = compileGlobs(["*.ms", "a**b", "**/*.cms"]);
	assert result.globs.length === 2;
	assert result.errors.length === 1;
}
