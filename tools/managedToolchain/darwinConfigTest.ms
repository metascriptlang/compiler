import {
	DarwinTarget, darwinTargetName, parseDarwinTarget, darwinConfigName,
	renderDarwinConfig, selectDarwinTargets,
} from "./darwinConfig";

const ARM64_CONFIG = "--target=aarch64-apple-macos11.0\n" +
	"-isysroot <CFGDIR>/sysroot\n" +
	"--ld-path=<CFGDIR>/../../bin/ld64.lld\n";
const X64_CONFIG = "--target=x86_64-apple-macos11.0\n" +
	"-isysroot <CFGDIR>/sysroot\n" +
	"--ld-path=<CFGDIR>/../../bin/ld64.lld\n";
const ARM64_NAME = "aarch64-macos";
const X64_NAME = "x86_64-macos";

let cases: int32 = 0;

function equal(actual: string, expected: string, what: string): void {
	if (actual != expected) { throw new Error(what + " changed: " + actual); }
	cases += 1;
}

function expectSelection(
	names: string[],
	expected: DarwinTarget[],
	what: string,
): void {
	const selected = selectDarwinTargets(names);
	if (!selected.ok) { throw new Error(what + " refused: " + selected.error); }
	if (selected.value.length != expected.length) {
		throw new Error(what + " selected a different count");
	}
	for (let index: int32 = 0; index < expected.length; index += 1) {
		if (selected.value[index] != expected[index]) {
			throw new Error(what + " selected a different order");
		}
	}
	cases += 1;
}

function expectRefusal(names: string[], what: string): void {
	if (selectDarwinTargets(names).ok) {
		throw new Error("accepted " + what);
	}
	cases += 1;
}

const targets = [DarwinTarget.Arm64, DarwinTarget.X64];
const goldens = [ARM64_CONFIG, X64_CONFIG];
const names = [ARM64_NAME, X64_NAME];
for (let index: int32 = 0; index < targets.length; index += 1) {
	const target = targets[index];
	const name = names[index];
	equal(darwinTargetName(target), name, "target name");
	equal(darwinConfigName(target), name + ".cfg", "config basename");
	const parsed = parseDarwinTarget(name);
	if (!parsed.ok || parsed.value != target) {
		throw new Error("target parse changed");
	}
	cases += 1;
	const rendered = renderDarwinConfig(target);
	equal(rendered, goldens[index], "config bytes");
	if (!rendered.endsWith("\n") || rendered.endsWith("\n\n")) {
		throw new Error("config does not end in exactly one LF");
	}
	cases += 1;
	if (rendered.split("\n").length != 4) {
		throw new Error("config is not three lines");
	}
	cases += 1;
	for (const forbidden of [
		"macos12", "macos13", "macos14", "macos15", "/usr/", "/Library/",
		"-nostdlib", "-nostartfiles", "-nodefaultlibs", "-stdlib",
		"-lc++", "-lunwind", "-resource-dir", "-rpath", "darwin/",
	]) {
		if (rendered.indexOf(forbidden) >= 0) {
			throw new Error("config adds forbidden policy: " + forbidden);
		}
		cases += 1;
	}
}
if (renderDarwinConfig(DarwinTarget.Arm64).indexOf("x86_64") >= 0) {
	throw new Error("arm64 config names another architecture");
}
cases += 1;
if (renderDarwinConfig(DarwinTarget.X64).indexOf("aarch64") >= 0) {
	throw new Error("x64 config names another architecture");
}
cases += 1;

for (const text of [
	"", "aarch64", "arm64-macos", "x86_64-linux", "x86_64-macos11.0",
	"aarch64-apple-macos11.0", "AARCH64-MACOS", " x86_64-macos", "../x",
	"darwin/x86_64-macos",
]) {
	if (parseDarwinTarget(text).ok) {
		throw new Error("accepted unsupported Darwin target: " + text);
	}
	cases += 1;
}

expectSelection([], targets, "empty selection");
expectSelection([ARM64_NAME], [DarwinTarget.Arm64], "arm64 only");
expectSelection([X64_NAME], [DarwinTarget.X64], "x64 only");
expectSelection([ARM64_NAME, X64_NAME], targets, "canonical order");
expectSelection([X64_NAME, ARM64_NAME], targets, "reversed input order");
expectRefusal(["i686-macos"], "unknown target");
expectRefusal([ARM64_NAME, "x86_64-linux"], "unknown beside known");
expectRefusal([""], "empty name");
expectRefusal([ARM64_NAME, ARM64_NAME], "duplicate arm64");
expectRefusal([X64_NAME, ARM64_NAME, X64_NAME], "duplicate x64");

when (!testBuild) {
	console.log("darwin config: " + String(cases) + " cases OK");
}
