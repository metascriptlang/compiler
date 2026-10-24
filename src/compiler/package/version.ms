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
	major: uint64;
	minor: uint64;
	patch: uint64;
	pre: string;        // empty string if no pre-release
}

export enum VersionError {
	TooShort,
	RangeOperator,
	VPrefix,
	WrongPartCount,
	BadNumber,
	BadPrerelease,
}

export function versionErrorMessage(e: VersionError): string {
	return match (e) {
		VersionError.TooShort => "too short for <major>.<minor>.<patch>",
		VersionError.RangeOperator => "range operators are not allowed",
		VersionError.VPrefix => "a v prefix is not allowed",
		VersionError.WrongPartCount => "expected exactly <major>.<minor>.<patch>",
		VersionError.BadNumber => "a version number is empty, has a leading zero, is not " +
			"a number or does not fit in 64 bits",
		VersionError.BadPrerelease => "the pre-release part is not valid",
	};
}

const UINT64_MAX: uint64 = 0xffffffffffffffff;

// --- Private helpers ---

// Parse a strict digit sequence: not empty, no leading zero ("0" alone is fine),
// only digits, and it must fit in a uint64.
function parseDigitsStrict(s: string, start: int32, end: int32): Result<uint64, VersionError> {
	if (end <= start) return Result.err(VersionError.BadNumber);
	if (end - start > 1 && s.charAt(start) == "0") return Result.err(VersionError.BadNumber);
	let result: uint64 = 0;
	for (let i = start; i < end; i++) {
		const c = s.byteAt(i);
		if (c < "0".code || c > "9".code) return Result.err(VersionError.BadNumber);
		const digit = (c - "0".code) as uint64;
		if (result > (UINT64_MAX - digit) / 10) return Result.err(VersionError.BadNumber);
		result = result * 10 + digit;
	}
	return Result.ok(result);
}

// Find the next `.` in s at or after start, before end. Returns -1 if not found.
function findDot(s: string, start: int32, end: int32): int32 {
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
function comparePrerelease(a: string, b: string): int32 {
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
			if (aId.length != bId.length) return aId.length < bId.length ? -1 : 1;
			if (aId != bId) return aId < bId ? -1 : 1;
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

// Parse a version string "<M>.<m>.<p>[-pre]". Range operators, wildcards and a
// "v" prefix are rejected, each with its own error.
export function parseVersion(s: string): Result<ParsedVersion, VersionError> {
	if (s.length < 5) return Result.err(VersionError.TooShort);          // minimum valid: "0.0.0"
	if (hasRangeOperator(s)) return Result.err(VersionError.RangeOperator);
	if (s.charAt(0) == "v") return Result.err(VersionError.VPrefix);

	const preDash = s.indexOf("-");
	const versionEnd = preDash >= 0 ? preDash : s.length;

	const dot1 = findDot(s, 0, versionEnd);
	if (dot1 < 0) return Result.err(VersionError.WrongPartCount);
	const dot2 = findDot(s, dot1 + 1, versionEnd);
	if (dot2 < 0) return Result.err(VersionError.WrongPartCount);
	if (findDot(s, dot2 + 1, versionEnd) >= 0) return Result.err(VersionError.WrongPartCount);

	const major = try parseDigitsStrict(s, 0, dot1);
	const minor = try parseDigitsStrict(s, dot1 + 1, dot2);
	const patch = try parseDigitsStrict(s, dot2 + 1, versionEnd);

	let pre = "";
	if (preDash >= 0) {
		pre = s.slice(preDash + 1, s.length);
		if (!isValidPrerelease(pre)) return Result.err(VersionError.BadPrerelease);
	}

	return Result.ok({ major, minor, patch, pre });
}

// Convenience: returns true iff s is a valid version string.
export function isValidVersion(s: string): boolean {
	return parseVersion(s).ok;
}

// Compare two parsed versions. Returns -1, 0, or 1.
// Release > pre-release (v1.2.3 > v1.2.3-rc1).
export function compareVersions(a: ParsedVersion, b: ParsedVersion): int32 {
	if (a.major != b.major) return a.major < b.major ? -1 : 1;
	if (a.minor != b.minor) return a.minor < b.minor ? -1 : 1;
	if (a.patch != b.patch) return a.patch < b.patch ? -1 : 1;

	if (a.pre == "" && b.pre == "") return 0;
	if (a.pre == "") return 1;       // release > pre-release
	if (b.pre == "") return -1;
	return comparePrerelease(a.pre, b.pre);
}

// Convenience: compare two version strings. Returns -1/0/1, or why one of them is invalid.
export function compareVersionStrings(a: string, b: string): Result<int32, VersionError> {
	const pa = try parseVersion(a);
	const pb = try parseVersion(b);
	return Result.ok(compareVersions(pa, pb));
}

// MVS helper: returns the largest version string from the list.
// Returns empty string if the list is empty or contains any invalid version.
export function maxVersion(versions: string[]): string {
	if (versions.length == 0) return "";
	const first = parseVersion(versions[0]);
	if (!first.ok) return "";
	let best = first.value;
	let bestStr = versions[0];
	for (let i = 1; i < versions.length; i++) {
		const cur = parseVersion(versions[i]);
		if (!cur.ok) return "";
		if (compareVersions(cur.value, best) > 0) {
			best = cur.value;
			bestStr = versions[i];
		}
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
}

export enum GitSpecError {
	NotGit,
	NoRef,
	UnknownHost,
}

export function gitSpecErrorMessage(e: GitSpecError): string {
	return match (e) {
		GitSpecError.NotGit => "a git source starts with git:",
		GitSpecError.NoRef => "a git source needs <host>/<path>@<ref>",
		GitSpecError.UnknownHost => "the git host is not one of the known hosts",
	};
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

// Parse a git source spec: "git:<host>/<path>@<ref>"
// The ref is any tag name the repo uses or a 40-char commit SHA; only an empty
// ref is rejected here, the archive fetch validates the rest.
export function parseGitSpec(s: string): Result<ParsedGitSpec, GitSpecError> {
	if (!s.startsWith("git:")) return Result.err(GitSpecError.NotGit);

	const rest = s.slice(4, s.length);  // "github.com/owner/repo@v1.2.3"
	// Split on LAST @ — URL may contain slashes but not @
	const atIdx = rest.lastIndexOf("@");
	if (atIdx < 1) return Result.err(GitSpecError.NoRef);

	const url = rest.slice(0, atIdx);
	const gitRef = rest.slice(atIdx + 1, rest.length);
	if (gitRef.length == 0) return Result.err(GitSpecError.NoRef);

	const slash = url.indexOf("/");
	const host = slash >= 0 ? url.slice(0, slash) : url;
	if (!isKnownHost(host)) return Result.err(GitSpecError.UnknownHost);

	return Result.ok({ url, ref: gitRef });
}

// Classify a dependency version string as a registry or git source.
export function sourceKindOf(s: string): SourceKind {
	return s.startsWith("git:") ? SourceKind.Git : SourceKind.Registry;
}

// --- Inline tests ---

function parsedVersion(s: string): ParsedVersion {
	const r = parseVersion(s);
	if (r.ok) return r.value;
	return { major: 0, minor: 0, patch: 0, pre: "!" };
}

function failsWith(s: string, e: VersionError): boolean {
	const r = parseVersion(s);
	if (r.ok) return false;
	return r.error == e;
}

function comparesAs(a: string, b: string, expected: int32): boolean {
	const r = compareVersionStrings(a, b);
	if (!r.ok) return false;
	return r.value == expected;
}

test "parseVersion v1.2.3" {
	const v = parsedVersion("1.2.3");
	assert v.major == 1;
	assert v.minor == 2;
	assert v.patch == 3;
	assert v.pre == "";
}

test "parseVersion 0.0.0" {
	const v = parsedVersion("0.0.0");
	assert v.pre == "";
	assert v.major == 0;
	assert v.minor == 0;
	assert v.patch == 0;
}

test "parseVersion large numbers" {
	const v = parsedVersion("123.456.789");
	assert v.major == 123;
	assert v.minor == 456;
	assert v.patch == 789;
}

test "parseVersion with prerelease" {
	const v = parsedVersion("1.2.3-rc1");
	assert v.major == 1;
	assert v.pre == "rc1";
}

test "parseVersion prerelease with dots" {
	const v = parsedVersion("1.2.3-alpha.4");
	assert v.pre == "alpha.4";
}

test "parseVersion bare version without v prefix" {
	const v = parsedVersion("1.2.3");
	assert v.major == 1;
	assert v.minor == 2;
	assert v.patch == 3;
}

test "parseVersion rejects v prefix" {
	assert !parseVersion("v1.2.3").ok;
}

test "parseVersion rejects leading zero in major" {
	assert !parseVersion("01.2.3").ok;
}

test "parseVersion rejects leading zero in minor" {
	assert !parseVersion("1.02.3").ok;
}

test "parseVersion rejects leading zero in patch" {
	assert !parseVersion("1.2.03").ok;
}

test "parseVersion allows zero-valued components" {
	assert parseVersion("1.1.0").ok;
	assert parseVersion("1.0.0").ok;
	assert parseVersion("1.0.1").ok;
}

test "parseVersion rejects incomplete v1.2" {
	assert !parseVersion("1.2").ok;
}

test "parseVersion rejects incomplete single number" {
	assert !parseVersion("1").ok;
}

test "parseVersion rejects bare v" {
	assert !parseVersion("v").ok;
}

test "parseVersion rejects empty string" {
	assert !parseVersion("").ok;
}

test "parseVersion rejects four-component" {
	assert !parseVersion("1.2.3.4").ok;
}

test "parseVersion rejects caret range" {
	assert !parseVersion("^1.2.3").ok;
}

test "parseVersion rejects tilde range" {
	assert !parseVersion("~1.2.3").ok;
}

test "parseVersion rejects gte range" {
	assert !parseVersion(">=1.2.3").ok;
}

test "parseVersion rejects wildcard star" {
	assert !parseVersion("*").ok;
}

test "parseVersion rejects empty prerelease" {
	assert !parseVersion("1.2.3-").ok;
}

test "parseVersion rejects prerelease with leading zero numeric id" {
	assert !parseVersion("1.2.3-01").ok;
}

test "parseVersion allows prerelease single 0" {
	assert parseVersion("1.2.3-0").ok;
}

test "compareVersions equal" {
	assert comparesAs("1.2.3", "1.2.3", 0);
}

test "compareVersions major order" {
	assert comparesAs("1.0.0", "2.0.0", -1);
	assert comparesAs("2.0.0", "1.0.0", 1);
}

test "compareVersions minor order" {
	assert comparesAs("1.2.0", "1.3.0", -1);
}

test "compareVersions patch order" {
	assert comparesAs("1.2.3", "1.2.4", -1);
}

test "compareVersions prerelease less than release" {
	assert comparesAs("1.2.3-rc1", "1.2.3", -1);
	assert comparesAs("1.2.3", "1.2.3-rc1", 1);
}

test "compareVersions prerelease numeric order" {
	assert comparesAs("1.0.0-1", "1.0.0-2", -1);
	assert comparesAs("1.0.0-10", "1.0.0-2", 1);
}

test "compareVersions prerelease alphanumeric order" {
	assert comparesAs("1.0.0-alpha", "1.0.0-beta", -1);
}

test "compareVersions numeric lower than alphanumeric" {
	assert comparesAs("1.0.0-1", "1.0.0-alpha", -1);
}

test "compareVersions prerelease fewer ids first" {
	assert comparesAs("1.0.0-alpha", "1.0.0-alpha.1", -1);
}

test "compareVersionStrings names why a side is invalid" {
	const bad = compareVersionStrings("1.2.3", "bad");
	assert !bad.ok;
	if (!bad.ok) assert bad.error == VersionError.TooShort;
	const range = compareVersionStrings("^1.2.3", "1.2.3");
	assert !range.ok;
	if (!range.ok) assert range.error == VersionError.RangeOperator;
}

test "parseVersion reports the reason" {
	assert failsWith("1.2", VersionError.TooShort);
	assert failsWith("^1.2.3", VersionError.RangeOperator);
	assert failsWith("v1.2.3", VersionError.VPrefix);
	assert failsWith("1.2.3.4", VersionError.WrongPartCount);
	assert failsWith("1.2.x", VersionError.BadNumber);
	assert failsWith("1.02.3", VersionError.BadNumber);
	assert failsWith("1.2.3-", VersionError.BadPrerelease);
}

test "a version number past 64 bits is refused, the largest one is kept" {
	assert failsWith("99999999999999999999.0.0", VersionError.BadNumber);
	assert failsWith("18446744073709551616.0.0", VersionError.BadNumber);
	assert parsedVersion("18446744073709551615.0.0").major == 0xffffffffffffffff;
}

test "a numeric pre-release identifier of any length compares by value" {
	assert comparesAs("1.0.0-99999999999999999999", "1.0.0-100000000000000000000", -1);
	assert comparesAs("1.0.0-9", "1.0.0-10", -1);
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

function parsedGit(s: string): ParsedGitSpec {
	const r = parseGitSpec(s);
	if (r.ok) return r.value;
	return { url: "", ref: "" };
}

function gitFailsWith(s: string, e: GitSpecError): boolean {
	const r = parseGitSpec(s);
	if (r.ok) return false;
	return r.error == e;
}

test "parseGitSpec valid tag" {
	const g = parsedGit("git:github.com/acme/foo@v1.2.3");
	assert g.url == "github.com/acme/foo";
	assert g.ref == "v1.2.3";  // git ref preserves the original tag name
}

test "parseGitSpec valid SHA" {
	const g = parsedGit("git:github.com/acme/foo@abcdef1234567890abcdef1234567890abcdef12");
	assert g.ref == "abcdef1234567890abcdef1234567890abcdef12";
}

test "parseGitSpec accepts every known host" {
	assert parsedGit("git:gitlab.com/group/project@v2.0.0").url == "gitlab.com/group/project";
	assert parseGitSpec("git:bitbucket.org/team/repo@v1.0.0").ok;
	assert parseGitSpec("git:codeberg.org/user/repo@v0.1.0").ok;
}

test "parseGitSpec accepts a branch or a short ref" {
	assert parsedGit("git:github.com/acme/foo@main").ref == "main";
	assert parsedGit("git:github.com/acme/foo@abc123").ref == "abc123";
}

test "parseGitSpec reports why a spec is refused" {
	assert gitFailsWith("git:example.com/foo/bar@v1.0.0", GitSpecError.UnknownHost);
	assert gitFailsWith("github.com/acme/foo@v1.0.0", GitSpecError.NotGit);
	assert gitFailsWith("git:github.com/acme/foo@", GitSpecError.NoRef);
	assert gitFailsWith("git:github.com/acme/foo", GitSpecError.NoRef);
	assert gitFailsWith("git:@v1.0.0", GitSpecError.NoRef);
}

// --- sourceKindOf tests ---

test "sourceKindOf tells git from registry" {
	assert sourceKindOf("1.2.3") == SourceKind.Registry;
	assert sourceKindOf("not-a-version") == SourceKind.Registry;
	assert sourceKindOf("git:github.com/acme/foo@v1.2.3") == SourceKind.Git;
	assert sourceKindOf("git:") == SourceKind.Git;
}
