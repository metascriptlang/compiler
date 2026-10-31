// @stdout: Child env pairs: 22 cases OK
import { childEnvironmentPairs } from "std/process/environment";

struct Pair { key: string; value: string; }
let checks: int32 = 0;

function variables(rows: Pair[]): Map<string, string> {
	const result = new Map<string, string>();
	for (const row of rows) { result.set(row.key, row.value); }
	return result;
}

function check(
	name: string, rows: Pair[], windows: boolean, expected: string[],
): void {
	const input = variables(rows);
	const order = input.keys().join("|");
	const result = childEnvironmentPairs(input, windows);
	if (!result.ok) { throw new Error(name + ": " + result.error); }
	if (result.value.length != expected.length) {
		throw new Error(name + ": pair count differs");
	}
	for (let i: int32 = 0; i < expected.length; i += 1) {
		if (result.value[i] != expected[i]) {
			throw new Error(name + ": pair differs at " + String(i));
		}
	}
	if (input.keys().join("|") != order || input.size != rows.length) {
		throw new Error(name + ": caller map changed");
	}
	for (const row of rows) {
		if (input.get(row.key) != row.value) {
			throw new Error(name + ": caller value changed");
		}
	}
	checks += 1;
}

function refused(name: string, rows: Pair[], windows: boolean): void {
	const result = childEnvironmentPairs(variables(rows), windows);
	if (result.ok || !result.error.contains("NUL")) {
		throw new Error(name + ": did not refuse NUL");
	}
	checks += 1;
}

check("empty POSIX", [], false, []);
check("empty Windows", [], true, []);
check("POSIX keeps case and order", [
	{ key: "a", value: "first" }, { key: "A", value: "second" },
], false, ["a=first", "A=second"]);
check("Windows chooses sorted first", [
	{ key: "a", value: "first" }, { key: "A", value: "second" },
], true, ["A=second"]);
check("Windows full expansion", [
	{ key: "straße", value: "sharp" }, { key: "STRASSE", value: "plain" },
], true, ["STRASSE=plain"]);
check("Windows sigma variants", [
	{ key: "σ", value: "middle" }, { key: "ς", value: "final" },
	{ key: "Σ", value: "capital" },
], true, ["Σ=capital"]);
check("Windows long s", [
	{ key: "ſ", value: "long" }, { key: "S", value: "ASCII" },
], true, ["S=ASCII"]);
check("no Unicode normalization", [
	{ key: "İ", value: "one" }, { key: "i\u0307", value: "two" },
], true, ["i\u0307=two", "İ=one"]);
check("UTF16 key sort", [
	{ key: "\uE000", value: "BMP" }, { key: "\u{10000}", value: "astral" },
], true, ["\u{10000}=astral", "\uE000=BMP"]);
check("value equals", [{ key: "A", value: "x=y" }], false, ["A=x=y"]);
check("empty value wins", [
	{ key: "PATH", value: "" }, { key: "path", value: "other" },
], true, ["PATH="]);
refused("POSIX key NUL", [{ key: "A\0", value: "x" }], false);
refused("Windows key NUL", [{ key: "A\0", value: "x" }], true);
refused("POSIX value NUL", [{ key: "A", value: "x\0y" }], false);
refused("Windows value NUL", [{ key: "A", value: "x\0y" }], true);
check("ignored case loser is not passed", [
	{ key: "a", value: "bad\0" }, { key: "A", value: "safe" },
], true, ["A=safe"]);
check("POSIX lone surrogate value encodes", [
	{ key: "A", value: "\uD800" },
], false, ["A=\uFFFD"]);
check("Windows lone surrogate value encodes", [
	{ key: "A", value: "\uD800" },
], true, ["A=\uFFFD"]);
check("POSIX lone surrogate key encodes", [
	{ key: "\uD800", value: "x" },
], false, ["\uFFFD=x"]);
check("Windows lone surrogate key encodes", [
	{ key: "\uD800", value: "x" },
], true, ["\uFFFD=x"]);
check("Unicode scalar value", [
	{ key: "A", value: "é🚀" },
], false, ["A=é🚀"]);
check("paired surrogates encode as one scalar", [
	{ key: "A", value: "\uD800\uDC00" },
], true, ["A=𐀀"]);
console.log("Child env pairs: " + String(checks) + " cases OK");
