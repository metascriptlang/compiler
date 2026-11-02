import {
	ManifestEntry,
	renderManifest,
	parseManifest,
	parseHeader,
	manifestIdentity,
	verifyIdentity,
} from "./manifest";

const DIGEST = "a".repeat(64);
let cases: int32 = 0;

function expectText(entries: ManifestEntry[], expected: string): void {
	const result = renderManifest(entries);
	if (!result.ok) { throw new Error(result.error); }
	if (result.value != expected) { throw new Error("manifest bytes differ"); }
	cases += 1;
}

function expectRefusal(entries: ManifestEntry[], message: string): void {
	const result = renderManifest(entries);
	if (result.ok) { throw new Error("accepted invalid manifest"); }
	if (result.error.indexOf(message) < 0) { throw new Error(result.error); }
	cases += 1;
}

expectText([], "");
expectText(
	[{ path: "HOST", digest: DIGEST }, { path: "VERSION", digest: DIGEST }],
	DIGEST + "  HOST\n" + DIGEST + "  VERSION\n",
);
expectText(
	[{ path: "bin/path with spaces", digest: DIGEST }],
	DIGEST + "  bin/path with spaces\n",
);
expectText(
	[{ path: "\uE000", digest: DIGEST }, { path: "🚀", digest: DIGEST }],
	DIGEST + "  \uE000\n" + DIGEST + "  🚀\n",
);
for (const path of [
	"", "../escape", "/abs", "a/./b", "a//b", "a\\b", "a/../b", "a/",
	"a\0b", "a\rb", "a\nb", "C:drive", "D:/escape", "FILES.sha256", "IDENTITY",
]) {
	expectRefusal([{ path, digest: DIGEST }], "unsafe path");
}
for (const digest of ["", "A".repeat(64), "g".repeat(64), "a".repeat(63)]) {
	expectRefusal([{ path: "HOST", digest }], "bad digest");
}
expectRefusal(
	[{ path: "b", digest: DIGEST }, { path: "a", digest: DIGEST }],
	"not unique and sorted",
);
expectRefusal(
	[{ path: "a", digest: DIGEST }, { path: "a", digest: DIGEST }],
	"not unique and sorted",
);
expectRefusal(
	[{ path: "🚀", digest: DIGEST }, { path: "\uE000", digest: DIGEST }],
	"not unique and sorted",
);
const canonical = DIGEST + "  HOST\n" + DIGEST + "  VERSION\n";
const parsed = parseManifest(canonical);
if (!parsed.ok) { throw new Error(parsed.error); }
expectText(parsed.value, canonical);
for (const text of [
	DIGEST + "  HOST",
	DIGEST + " HOST\n",
	DIGEST.toUpperCase() + "  HOST\n",
	canonical + "\n",
	DIGEST + "  HOST\r\n",
	DIGEST + "  HOST\n" + DIGEST + "  HOST\n",
	DIGEST + "  b\n" + DIGEST + "  a\n",
	DIGEST + "  ../outside\n",
]) {
	const result = parseManifest(text);
	if (result.ok) { throw new Error("accepted malformed manifest: " + text); }
	cases += 1;
}
for (const host of [
	"aarch64-macos", "x86_64-macos", "x86_64-linux", "aarch64-linux",
	"x86_64-windows", "aarch64-windows",
]) {
	const result = parseHeader(host + "\n", "23.1.0\n");
	if (!result.ok) { throw new Error(result.error); }
	if (result.value.host != host || result.value.version != "23.1.0") {
		throw new Error("header values differ");
	}
	cases += 1;
}
for (const host of [
	"riscv-macos\n", "x86_64-linux", "x86_64-linux\r\n",
	"x86_64-linux\nextra\n", "",
]) {
	if (parseHeader(host, "23.1.0\n").ok) {
		throw new Error("accepted malformed HOST");
	}
	cases += 1;
}
for (const version of [
	"22.1\n", "22..1\n", "22.1.1\nextra\n", "-1.0.0\n", "22x.1.1\n",
	"22.1.1", "22.1.1\r\n", "",
]) {
	if (parseHeader("x86_64-linux\n", version).ok) {
		throw new Error("accepted malformed VERSION");
	}
	cases += 1;
}
const emptyDigest =
	"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const identity = manifestIdentity("");
if (!identity.ok) { throw new Error(identity.error); }
if (identity.value != emptyDigest + "\n") {
	throw new Error("IDENTITY bytes differ");
}
cases += 1;
if (!verifyIdentity("", emptyDigest + "\n").ok) {
	throw new Error("correct IDENTITY refused");
}
cases += 1;
if (verifyIdentity("abc", emptyDigest + "\n").ok) {
	throw new Error("changed manifest passed IDENTITY");
}
cases += 1;
for (const line of [
	"", DIGEST, DIGEST.toUpperCase() + "\n", DIGEST + "\r\n",
	"a".repeat(63) + "\n", DIGEST + "\nextra\n",
]) {
	if (verifyIdentity(canonical, line).ok) {
		throw new Error("accepted malformed IDENTITY");
	}
	cases += 1;
}
console.log("manifest/header/identity: " + String(cases) + " cases OK");
