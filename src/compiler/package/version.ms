// Version parsing for the MetaScript package manager.
//
// Format: "v<major>.<minor>.<patch>[-<prerelease>]"
// Examples: "1.1.0", "1.2.3", "1.0.0-rc1", "1.4.7-alpha.3"
//
// No range operators allowed. Every dep version is an EXACT MINIMUM.
// Version selection is done via Minimum Version Selection (MVS), not SAT solving.
// See docs/PACKAGE.md for the full specification.

// --- Types ---

export interface ParsedVersion {
	major: number;
	minor: number;
	patch: number;
	pre: string;        // empty string if no pre-release
	isValid: boolean;
}

// --- Private helpers ---

// Parse a strict digit sequence. Returns -1 on empty, leading-zero, or non-digit.
// A single "0" is allowed; "01" or "007" are not.
function parseDigitsStrict(s: string, start: number, end: number): number {
	if (end <= start) return -1;
	if (end - start > 1 && s.charAt(start) == "0") return -1;
	let result = 0;
	let i = start;
	while (i < end) {
		const c = s.byteAt(i);
		if (c < "0".code || c > "9".code) return -1;
		result = result * 10 + (c - "0".code);
		i = i + 1;
	}
	return result;
}

// Find the next `.` in s at or after start, before end. Returns -1 if not found.
function findDot(s: string, start: number, end: number): number {
	let i = start;
	while (i < end) {
		if (s.charAt(i) == ".") return i;
		i = i + 1;
	}
	return -1;
}

// Detect range operators at the start of a version string. We reject these
// unambiguously to protect MVS semantics — every dep must be an exact minimum.
function hasRangeOperator(s: string): boolean {
	if (s.length == 0) return false;
	return match (s.charAt(0)) {
		"^" | "~" | ">" | "<" | "=" | "*" => true,
		_ => false,
	};
}

// Validate a pre-release string: one or more dot-separated identifiers,
// each matching [0-9A-Za-z-]+, none empty, numeric identifiers have no leading zero.
function isValidPrerelease(s: string): boolean {
	if (s.length == 0) return false;
	let start = 0;
	let i = 0;
	while (i <= s.length) {
		if (i == s.length || s.charAt(i) == ".") {
			if (i == start) return false;  // empty identifier
			let allDigitsSeen = true;
			let j = start;
			while (j < i) {
				const c = s.byteAt(j);
				const isDigit = c >= "0".code && c <= "9".code;
				const isLower = c >= "a".code && c <= "z".code;
				const isUpper = c >= "A".code && c <= "Z".code;
				const isDash = c == "-".code;
				if (!isDigit && !isLower && !isUpper && !isDash) return false;
				if (!isDigit) allDigitsSeen = false;
				j = j + 1;
			}
			// Numeric identifier must not have a leading zero (unless it IS "0")
			if (allDigitsSeen && (i - start) > 1 && s.charAt(start) == "0") return false;
			start = i + 1;
		}
		i = i + 1;
	}
	return true;
}

// Check if all characters in s are ASCII digits. Empty string returns false.
function allDigits(s: string): boolean {
	if (s.length == 0) return false;
	let i = 0;
	while (i < s.length) {
		const c = s.byteAt(i);
		if (c < "0".code || c > "9".code) return false;
		i = i + 1;
	}
	return true;
}

// Return the index of the next `.` in s at or after start, or s.length if none.
function nextIdEnd(s: string, start: int32): int32 {
	let i = start;
	while (i < s.length && s.charAt(i) != ".") i = i + 1;
	return i;
}

// Compare two pre-release strings identifier by identifier per semver rules:
// - Numeric identifiers compared numerically
// - Alphanumeric identifiers compared lexically
// - Numeric < alphanumeric when same position
// - Fewer identifiers < more identifiers when all equal so far
function comparePrerelease(a: string, b: string): number {
	let aStart = 0;
	let bStart = 0;
	while (aStart < a.length || bStart < b.length) {
		if (aStart >= a.length) return -1;
		if (bStart >= b.length) return 1;

		const aEnd = nextIdEnd(a, aStart);
		const bEnd = nextIdEnd(b, bStart);
		const aId = a.slice(aStart, aEnd);
		const bId = b.slice(bStart, bEnd);

		const aNum = allDigits(aId);
		const bNum = allDigits(bId);

		if (aNum && bNum) {
			const an = parseDigitsStrict(aId, 0, aId.length);
			const bn = parseDigitsStrict(bId, 0, bId.length);
			if (an != bn) return an < bn ? -1 : 1;
		} else if (aNum) {
			return -1;  // numeric < alphanumeric
		} else if (bNum) {
			return 1;
		} else {
			if (aId < bId) return -1;
			if (aId > bId) return 1;
		}

		aStart = aEnd + 1;
		bStart = bEnd + 1;
	}
	return 0;
}

// --- Public API ---

// Parse a version string. Returns ParsedVersion with isValid=false if the string
// is not a valid "v<M>.<m>.<p>[-pre]" literal. Range operators and wildcards are
// rejected — callers should surface a clear error message in that case.
export function parseVersion(s: string): ParsedVersion {
	const invalid: ParsedVersion = { major: -1, minor: -1, patch: -1, pre: "", isValid: false };
	if (s.length < 5) return invalid;          // minimum valid: "0.0.0"
	if (hasRangeOperator(s)) return invalid;

	// No "v" prefix allowed — versions are bare semver: "1.2.3", not "v1.2.3"
	if (s.charAt(0) == "v") return invalid;
	let start = 0;

	const len = s.length;

	// Find where the version ends (start of "-pre" if present, else end of string).
	let versionEnd = len;
	let preStart = -1;
	let scan = start;
	while (scan < len) {
		if (s.charAt(scan) == "-") {
			versionEnd = scan;
			preStart = scan + 1;
			scan = len;
		} else {
			scan = scan + 1;
		}
	}

	// Parse major.minor.patch from [start .. versionEnd].
	const dot1 = findDot(s, start, versionEnd);
	if (dot1 < 0) return invalid;
	const dot2 = findDot(s, dot1 + 1, versionEnd);
	if (dot2 < 0) return invalid;
	// Reject a third dot — rejects "1.2.3.4"
	const dot3 = findDot(s, dot2 + 1, versionEnd);
	if (dot3 >= 0) return invalid;

	const major = parseDigitsStrict(s, start, dot1);
	if (major < 0) return invalid;
	const minor = parseDigitsStrict(s, dot1 + 1, dot2);
	if (minor < 0) return invalid;
	const patch = parseDigitsStrict(s, dot2 + 1, versionEnd);
	if (patch < 0) return invalid;

	// Parse optional pre-release suffix.
	let pre = "";
	if (preStart >= 0) {
		pre = s.slice(preStart, len);
		if (!isValidPrerelease(pre)) return invalid;
	}

	return { major, minor, patch, pre, isValid: true };
}

// Convenience: returns true iff s is a valid version string.
export function isValidVersion(s: string): boolean {
	return parseVersion(s).isValid;
}

// Compare two parsed versions. Returns -1, 0, or 1.
// Release > pre-release (v1.2.3 > v1.2.3-rc1).
export function compareVersions(a: ParsedVersion, b: ParsedVersion): number {
	if (a.major != b.major) return a.major < b.major ? -1 : 1;
	if (a.minor != b.minor) return a.minor < b.minor ? -1 : 1;
	if (a.patch != b.patch) return a.patch < b.patch ? -1 : 1;

	if (a.pre == "" && b.pre == "") return 0;
	if (a.pre == "") return 1;       // release > pre-release
	if (b.pre == "") return -1;
	return comparePrerelease(a.pre, b.pre);
}

// Convenience: compare two version strings. Returns -1/0/1, or -2 if either is invalid.
export function compareVersionStrings(a: string, b: string): number {
	const pa = parseVersion(a);
	const pb = parseVersion(b);
	if (!pa.isValid || !pb.isValid) return -2;
	return compareVersions(pa, pb);
}

// MVS helper: returns the largest version string from the list.
// Returns empty string if the list is empty or contains any invalid version.
export function maxVersion(versions: string[]): string {
	if (versions.length == 0) return "";
	let best = parseVersion(versions[0]);
	if (!best.isValid) return "";
	let bestStr = versions[0];
	let i = 1;
	while (i < versions.length) {
		const cur = parseVersion(versions[i]);
		if (!cur.isValid) return "";
		if (compareVersions(cur, best) > 0) {
			best = cur;
			bestStr = versions[i];
		}
		i = i + 1;
	}
	return bestStr;
}

// --- Source type discrimination ---

export enum SourceKind {
	Registry,
	Git,
}

export interface ParsedGitSpec {
	url: string;          // "github.com/owner/repo" (normalized, no protocol)
	ref: string;          // tag "1.2.3" or 40-char SHA
	isValid: boolean;
}

// Well-known git hosts that provide HTTPS archive URLs (no git binary needed).
const KNOWN_GIT_HOSTS: string[] = ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"];

function isKnownHost(host: string): boolean {
	for (const kh of KNOWN_GIT_HOSTS) {
		if (host == kh) return true;
	}
	return false;
}

// Check if a string is a valid 40-character hex SHA.
function isHexSha40(s: string): boolean {
	if (s.length != 40) return false;
	let i = 0;
	while (i < 40) {
		const c = s.byteAt(i);
		const isDigit = c >= "0".code && c <= "9".code;
		const isLower = c >= "a".code && c <= "f".code;
		if (!isDigit && !isLower) return false;
		i = i + 1;
	}
	return true;
}

// Find the last occurrence of `@` in a string. Returns -1 if not found.
function findLastAt(s: string): number {
	let last = -1;
	let i = 0;
	while (i < s.length) {
		if (s.charAt(i) == "@") last = i;
		i = i + 1;
	}
	return last;
}

// Extract the host portion from a URL path like "github.com/owner/repo".
// Returns everything up to the first `/`.
function extractHost(url: string): string {
	let i = 0;
	while (i < url.length) {
		if (url.charAt(i) == "/") return url.slice(0, i);
		i = i + 1;
	}
	return url;
}

// Parse a git source spec: "git:<host>/<path>@<ref>"
// Returns ParsedGitSpec with isValid=false on any format error.
// Ref must be a tag (passes parseVersion) or a 40-char hex SHA.
// Branch-like refs (main, develop) are rejected in v1 per PACKAGE.md.
export function parseGitSpec(s: string): ParsedGitSpec {
	const invalid: ParsedGitSpec = { url: "", ref: "", isValid: false };
	if (s.length < 5) return invalid;
	// Must start with "git:"
	if (s.slice(0, 4) != "git:") return invalid;

	const rest = s.slice(4, s.length);  // "github.com/owner/repo@v1.2.3"
	// Split on LAST @ — URL may contain slashes but not @
	const atIdx = findLastAt(rest);
	if (atIdx < 1) return invalid;

	const url = rest.slice(0, atIdx);
	const gitRef = rest.slice(atIdx + 1, rest.length);
	if (url.length == 0 || gitRef.length == 0) return invalid;

	// Validate host is well-known
	const host = extractHost(url);
	if (!isKnownHost(host)) return invalid;

	// Git ref can be anything the repo uses as a tag name (v1.2.3, 1.2.3,
	// release-1.0, etc.) or a 40-char commit SHA. We don't validate the tag
	// format — that's the repo owner's convention. We only reject empty refs.
	// The real validation happens when we try to fetch the archive URL.

	return { url, ref: gitRef, isValid: true };
}

// Top-level dispatcher: classify a dependency version string as registry or git source.
export function parseSourceSpec(s: string): { kind: SourceKind, version: ParsedVersion, git: ParsedGitSpec } {
	if (s.length >= 4 && s.slice(0, 4) == "git:") {
		const git = parseGitSpec(s);
		const emptyVer: ParsedVersion = { major: -1, minor: -1, patch: -1, pre: "", isValid: false };
		return { kind: SourceKind.Git, version: emptyVer, git };
	}
	const ver = parseVersion(s);
	const emptyGit: ParsedGitSpec = { url: "", ref: "", isValid: false };
	return { kind: SourceKind.Registry, version: ver, git: emptyGit };
}

// --- Inline tests ---

test "parseVersion v1.2.3" {
	const v = parseVersion("1.2.3");
	assert v.isValid;
	assert v.major == 1;
	assert v.minor == 2;
	assert v.patch == 3;
	assert v.pre == "";
}

test "parseVersion 0.0.0" {
	const v = parseVersion("0.0.0");
	assert v.isValid;
	assert v.major == 0;
	assert v.minor == 0;
	assert v.patch == 0;
}

test "parseVersion large numbers" {
	const v = parseVersion("123.456.789");
	assert v.isValid;
	assert v.major == 123;
	assert v.minor == 456;
	assert v.patch == 789;
}

test "parseVersion with prerelease" {
	const v = parseVersion("1.2.3-rc1");
	assert v.isValid;
	assert v.major == 1;
	assert v.pre == "rc1";
}

test "parseVersion prerelease with dots" {
	const v = parseVersion("1.2.3-alpha.4");
	assert v.isValid;
	assert v.pre == "alpha.4";
}

test "parseVersion bare version without v prefix" {
	const v = parseVersion("1.2.3");
	assert v.isValid;
	assert v.major == 1;
	assert v.minor == 2;
	assert v.patch == 3;
}

test "parseVersion rejects v prefix" {
	assert !parseVersion("v1.2.3").isValid;
}

test "parseVersion rejects leading zero in major" {
	assert !parseVersion("01.2.3").isValid;
}

test "parseVersion rejects leading zero in minor" {
	assert !parseVersion("1.02.3").isValid;
}

test "parseVersion rejects leading zero in patch" {
	assert !parseVersion("1.2.03").isValid;
}

test "parseVersion allows zero-valued components" {
	assert parseVersion("1.1.0").isValid;
	assert parseVersion("1.0.0").isValid;
	assert parseVersion("1.0.1").isValid;
}

test "parseVersion rejects incomplete v1.2" {
	assert !parseVersion("1.2").isValid;
}

test "parseVersion rejects incomplete single number" {
	assert !parseVersion("1").isValid;
}

test "parseVersion rejects bare v" {
	assert !parseVersion("v").isValid;
}

test "parseVersion rejects empty string" {
	assert !parseVersion("").isValid;
}

test "parseVersion rejects four-component" {
	assert !parseVersion("1.2.3.4").isValid;
}

test "parseVersion rejects caret range" {
	assert !parseVersion("^1.2.3").isValid;
}

test "parseVersion rejects tilde range" {
	assert !parseVersion("~1.2.3").isValid;
}

test "parseVersion rejects gte range" {
	assert !parseVersion(">=1.2.3").isValid;
}

test "parseVersion rejects wildcard star" {
	assert !parseVersion("*").isValid;
}

test "parseVersion rejects empty prerelease" {
	assert !parseVersion("1.2.3-").isValid;
}

test "parseVersion rejects prerelease with leading zero numeric id" {
	assert !parseVersion("1.2.3-01").isValid;
}

test "parseVersion allows prerelease single 0" {
	assert parseVersion("1.2.3-0").isValid;
}

test "compareVersions equal" {
	assert compareVersionStrings("1.2.3", "1.2.3") == 0;
}

test "compareVersions major order" {
	assert compareVersionStrings("1.0.0", "2.0.0") == -1;
	assert compareVersionStrings("2.0.0", "1.0.0") == 1;
}

test "compareVersions minor order" {
	assert compareVersionStrings("1.2.0", "1.3.0") == -1;
}

test "compareVersions patch order" {
	assert compareVersionStrings("1.2.3", "1.2.4") == -1;
}

test "compareVersions prerelease less than release" {
	assert compareVersionStrings("1.2.3-rc1", "1.2.3") == -1;
	assert compareVersionStrings("1.2.3", "1.2.3-rc1") == 1;
}

test "compareVersions prerelease numeric order" {
	assert compareVersionStrings("1.0.0-1", "1.0.0-2") == -1;
	assert compareVersionStrings("1.0.0-10", "1.0.0-2") == 1;
}

test "compareVersions prerelease alphanumeric order" {
	assert compareVersionStrings("1.0.0-alpha", "1.0.0-beta") == -1;
}

test "compareVersions numeric lower than alphanumeric" {
	assert compareVersionStrings("1.0.0-1", "1.0.0-alpha") == -1;
}

test "compareVersions prerelease fewer ids first" {
	assert compareVersionStrings("1.0.0-alpha", "1.0.0-alpha.1") == -1;
}

test "compareVersions invalid returns sentinel" {
	assert compareVersionStrings("1.2.3", "bad") == -2;
}

test "maxVersion picks highest" {
	const vs: string[] = ["1.0.0", "1.2.3", "1.2.0"];
	assert maxVersion(vs) == "1.2.3";
}

test "maxVersion prefers release over prerelease" {
	const vs: string[] = ["1.2.3-rc1", "1.2.3"];
	assert maxVersion(vs) == "1.2.3";
}

test "maxVersion empty list" {
	const vs: string[] = [];
	assert maxVersion(vs) == "";
}

test "maxVersion single entry" {
	const vs: string[] = ["1.2.3"];
	assert maxVersion(vs) == "1.2.3";
}

test "maxVersion rejects any invalid entry" {
	const vs: string[] = ["1.2.3", "not-a-version"];
	assert maxVersion(vs) == "";
}

test "isValidVersion convenience" {
	assert isValidVersion("1.2.3");
	assert !isValidVersion("v1.2.3");
	assert !isValidVersion("");
	assert isValidVersion("1.0.0-rc1");
}

// --- Git spec tests ---

test "parseGitSpec valid tag" {
	const g = parseGitSpec("git:github.com/acme/foo@v1.2.3");
	assert g.isValid;
	assert g.url == "github.com/acme/foo";
	assert g.ref == "v1.2.3";  // git ref preserves the original tag name
}

test "parseGitSpec valid SHA" {
	const g = parseGitSpec("git:github.com/acme/foo@abcdef1234567890abcdef1234567890abcdef12");
	assert g.isValid;
	assert g.ref == "abcdef1234567890abcdef1234567890abcdef12";
}

test "parseGitSpec gitlab host" {
	const g = parseGitSpec("git:gitlab.com/group/project@v2.0.0");
	assert g.isValid;
	assert g.url == "gitlab.com/group/project";
}

test "parseGitSpec bitbucket host" {
	const g = parseGitSpec("git:bitbucket.org/team/repo@v1.0.0");
	assert g.isValid;
}

test "parseGitSpec codeberg host" {
	const g = parseGitSpec("git:codeberg.org/user/repo@v0.1.0");
	assert g.isValid;
}

test "parseGitSpec rejects unknown host" {
	assert !parseGitSpec("git:example.com/foo/bar@v1.0.0").isValid;
}

test "parseGitSpec accepts branch ref" {
	const g = parseGitSpec("git:github.com/acme/foo@main");
	assert g.isValid;
	assert g.ref == "main";
}

test "parseGitSpec accepts short ref" {
	const g = parseGitSpec("git:github.com/acme/foo@abc123");
	assert g.isValid;
	assert g.ref == "abc123";
}

test "parseGitSpec rejects missing git: prefix" {
	assert !parseGitSpec("github.com/acme/foo@v1.0.0").isValid;
}

test "parseGitSpec rejects empty ref" {
	assert !parseGitSpec("git:github.com/acme/foo@").isValid;
}

test "parseGitSpec rejects no @" {
	assert !parseGitSpec("git:github.com/acme/foo").isValid;
}

// --- parseSourceSpec tests ---

test "parseSourceSpec registry" {
	const s = parseSourceSpec("1.2.3");
	assert s.kind == SourceKind.Registry;
	assert s.version.isValid;
	assert s.version.major == 1;
}

test "parseSourceSpec git" {
	const s = parseSourceSpec("git:github.com/acme/foo@v1.2.3");
	assert s.kind == SourceKind.Git;
	assert s.git.isValid;
	assert s.git.url == "github.com/acme/foo";
}

test "parseSourceSpec invalid registry" {
	const s = parseSourceSpec("not-a-version");
	assert s.kind == SourceKind.Registry;
	assert !s.version.isValid;
}

test "parseSourceSpec invalid git" {
	const s = parseSourceSpec("git:example.com/foo@v1.0.0");
	assert s.kind == SourceKind.Git;
	assert !s.git.isValid;
}
