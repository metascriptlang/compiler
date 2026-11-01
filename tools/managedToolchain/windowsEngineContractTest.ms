import { sha256 } from "std/crypto";
import { readUtf8File } from "./textFile";
import { sortEnginePaths } from "./engineFiles";
import {
	WindowsPe, readWindowsPeText, windowsRoleProblem, checkWindowsDllName,
	parseWindowsToolVersion, addWindowsPlanned, asciiEngineJson,
	windowsTools, windowsSystemDlls,
} from "./windowsEngine";

let checks: int32 = 0;
function check(ok: boolean, label: string): void {
	if (!ok) { throw new Error(label); }
	checks += 1;
}
function pe(text: string): WindowsPe {
	const got = readWindowsPeText("subject.exe", text);
	if (!got.ok) { throw new Error(got.error); }
	return got.value;
}
function info(
	machine: uint32 = 0x8664, magic: uint32 = 0x20b,
	characteristics: uint32 = 0x22,
): WindowsPe {
	return { machine, magic, characteristics, imports: [], delayImports: [] };
}
function main(): void {
	const read = readUtf8File(
		"tools/managedToolchain/fixtures/windowsReadobj.txt");
	if (!read.ok) { throw new Error(read.error); }
	const fixture = read.value;
	const normalized = fixture.replaceAll("\r\n", "\n").replaceAll("\r", "\n");
	const digest = sha256(normalized);
	check(digest.ok && digest.value ==
		"d1f5d9817b12aef7b41d6a3a296516d01cc1605aed01c80b156f7eae7aa54128",
		"recorded fixture cohort after explicit universal-newline decoding");
	const recorded = pe(fixture);
	check(recorded.machine == 0x8664, "recorded machine");
	check(recorded.magic == 0x20b, "recorded PE32+ magic");
	check(recorded.characteristics == 0x22, "file flags, not DLL flags");
	check(recorded.imports.length == 1 && recorded.imports[0] == "ntdll.dll",
		"normal import");
	check(recorded.delayImports.length == 1 &&
		recorded.delayImports[0] == "ole32.dll", "nested delayed import");
	for (const text of [normalized, normalized.replaceAll("\n", "\r\n"),
		normalized.replaceAll("\n", "\r")]) {
		check(readWindowsPeText("subject.exe", text).ok, "line-ending variants");
	}
	check(pe(normalized.replace("(0x8664)", "(0x0000008664)")).machine ==
		0x8664, "leading zero hex digits are not an overflow");
	const good = "ImageFileHeader {\n" +
		"  Machine: IMAGE_FILE_MACHINE_AMD64 (0x8664)\n" +
		"  Characteristics [ (0x22)\n}\n" +
		"ImageOptionalHeader {\n  Magic: 0x20B\n}\n" +
		"Import {\n  Name: KERNEL32.dll\n}\n" +
		"DelayImport {\n  Name: ole32.dll\n  Import {\n    Address: 1\n  }\n}\n";
	const machine = "  Machine: IMAGE_FILE_MACHINE_AMD64 (0x8664)\n";
	const malformed = [
		{ label: "no file header", text: good.replace("ImageFileHeader {",
			"Other {"), error: "0 ImageFileHeader blocks" },
		{ label: "two file headers", text: good + "ImageFileHeader {\n}\n",
			error: "2 ImageFileHeader blocks" },
		{ label: "no optional header", text: good.replace("ImageOptionalHeader {",
			"Other {"), error: "0 ImageOptionalHeader blocks" },
		{ label: "no machine", text: good.replace(machine, ""),
			error: "0 ImageFileHeader Machine lines" },
		{ label: "two machines", text: good.replace(machine, machine + machine),
			error: "2 ImageFileHeader Machine lines" },
		{ label: "no flags", text: good.replace("  Characteristics [ (0x22)\n",
			""), error: "0 ImageFileHeader Characteristics lines" },
		{ label: "no magic", text: good.replace("  Magic: 0x20B\n", ""),
			error: "0 ImageOptionalHeader Magic lines" },
		{ label: "missing name", text: good.replace("  Name: KERNEL32.dll\n", ""),
			error: "Import block has no Name line first" },
		{ label: "missing delayed name", text: good +
			"DelayImport {\n  Attributes: 1\n}\n",
			error: "DelayImport block has no Name line first" },
		{ label: "empty import", text: good + "Import {\n}\n",
			error: "Import block has no Name line first" },
		{ label: "unterminated", text: good + "Import {\n  Name: x.dll\n",
			error: "ends inside block Import" },
		{ label: "nested top level", text: good.replace(
			"}\nImageOptionalHeader {", "ImageOptionalHeader {"),
			error: "starts inside block ImageFileHeader" },
		{ label: "empty output", text: "", error: "0 ImageFileHeader blocks" },
		{ label: "two optional headers", text: good +
			"ImageOptionalHeader {\n  Magic: 0x20B\n}\n",
			error: "2 ImageOptionalHeader blocks" },
		{ label: "header before imports", text: good.replace(
			"ImageFileHeader {", "Other {") + "Import {\n}\n",
			error: "0 ImageFileHeader blocks" },
		{ label: "invalid hex", text: good.replace("(0x8664)", "(0xGG)"),
			error: "0 ImageFileHeader Machine lines" },
		{ label: "two magic fields", text: good.replace("  Magic: 0x20B\n",
			"  Magic: 0x20B\n  Magic: 0x20B\n"),
			error: "2 ImageOptionalHeader Magic lines" },
	];
	for (const item of malformed) {
		const result = readWindowsPeText("subject.exe", item.text);
		check(!result.ok && result.error.startsWith("subject.exe: ") &&
			result.error.indexOf(item.error) >= 0, item.label);
	}
	for (const item of [
		{ label: "empty", name: "" },
		{ label: "leading space", name: " foo.dll" },
		{ label: "trailing space", name: "foo.dll " },
		{ label: "leading NBSP", name: "\u00a0foo.dll" },
		{ label: "trailing ideographic space", name: "foo.dll\u3000" },
	]) {
		const result = readWindowsPeText("subject.exe", good +
			"Import {\n  Name: " + item.name + "\n}\n");
		check(!result.ok && result.error.indexOf("no Name line first") >= 0,
			"import edge whitespace: " + item.label);
	}
	const breaks = ["\n", "\r", "\r\n", "\v", "\f", "\u001c", "\u001d",
		"\u001e", "\u0085", "\u2028", "\u2029"];
	for (let i: int32 = 0; i < breaks.length; i += 1) {
		const suffix = readWindowsPeText("subject.exe", good +
			"Import {\n  Name: foo.dll" + breaks[i] + "\n}\n");
		check(suffix.ok && suffix.value.imports.length == 2 &&
			suffix.value.imports[1] == "foo.dll",
			"line boundary after import name: " + String(i));
		const prefix = readWindowsPeText("subject.exe", good +
			"Import {\n  Name: " + breaks[i] + "foo.dll\n}\n");
		check(!prefix.ok && prefix.error.indexOf("no Name line first") >= 0,
			"line boundary before import name: " + String(i));
	}
	const x64 = "x86_64-windows";
	const arm64 = "aarch64-windows";
	const roles = [
		{ rel: "bin/a.exe", host: x64, info: info(), error: "" },
		{ rel: "bin/a.dll", host: x64, info: info(0x8664, 0x20b, 0x2022),
			error: "" },
		{ rel: "bin/A.EXE", host: x64, info: info(), error: "" },
		{ rel: "bin/A.DLL", host: x64, info: info(0x8664, 0x20b, 0x2022),
			error: "" },
		{ rel: "bin/a.exe", host: arm64, info: info(0xaa64), error: "" },
		{ rel: "bin/a.exe", host: x64, info: info(0x14c),
			error: "machine 0x14c" },
		{ rel: "bin/a.exe", host: x64, info: info(0xaa64),
			error: "machine 0xaa64" },
		{ rel: "bin/a.exe", host: x64, info: info(0x8664, 0x10b),
			error: "not PE32+" },
		{ rel: "bin/a.exe", host: x64, info: info(0x8664, 0x107),
			error: "not PE32+" },
		{ rel: "bin/a.exe", host: x64, info: info(0x8664, 0x20b, 0x2000),
			error: "not an executable image" },
		{ rel: "bin/a.exe", host: x64, info: info(0x8664, 0x20b, 0),
			error: "not an executable image" },
		{ rel: "bin/a.exe", host: x64, info: info(0x8664, 0x20b, 0x2022),
			error: "is a DLL image" },
		{ rel: "bin/a.dll", host: x64, info: info(),
			error: "required to be a DLL" },
		{ rel: "bin/a.exe", host: "x86_64-linux", info: info(),
			error: "unsupported Windows engine host" },
	];
	for (const item of roles) {
		const result = windowsRoleProblem(item.rel, item.info, item.host);
		check(item.error == "" ? result.ok :
			!result.ok && result.error.indexOf(item.error) >= 0,
			"PE role: " + item.rel + " " + item.error);
	}
	for (const name of ["foo.dll", "STRAẞE.DLL", "a b.dll"]) {
		check(checkWindowsDllName("owner", name).ok, "valid DLL basename");
	}
	for (const name of ["", ".", "..", "../evil.dll", "\\x.dll", "C:evil.dll",
		"a:b.dll", "bad\0.dll", "evil.exe", "evil", "foo.dll.exe"]) {
		check(!checkWindowsDllName("owner", name).ok, "invalid DLL basename");
	}
	const versions = [
		{ text: "clang version 23.1.0\n", prefix: "clang version ",
			version: "23.1.0" },
		{ text: "clang version broken\nclang version 22.1.1suffix",
			prefix: "clang version ", version: "22.1.1" },
		{ text: "LLVM version 23.1.0.1", prefix: "LLVM version ",
			version: "23.1.0" },
		{ text: "LLD 23.1.0", prefix: "LLD ", version: "23.1.0" },
		{ text: "clang version 23.1", prefix: "clang version ", version: "" },
		{ text: "clang version 23.1.0", prefix: "LLVM version ", version: "" },
	];
	for (const item of versions) {
		const result = parseWindowsToolVersion(item.text, item.prefix);
		check(item.version == "" ? !result.ok :
			result.ok && result.value == item.version, "tool version");
	}
	const plan = new Map<string, string>();
	const folds = new Map<string, string>();
	check(addWindowsPlanned(plan, folds, "bin/straße.dll", "source").ok,
		"new planned path");
	check(addWindowsPlanned(plan, folds, "bin/straße.dll", "source").ok,
		"identical source does not collide");
	const foldedCollision = addWindowsPlanned(plan, folds,
		"bin/STRASSE.DLL", "other");
	check(!foldedCollision.ok,
		"full fold, not lowercasing");
	check(!addWindowsPlanned(plan, folds, "bin/straße.dll", "other").ok,
		"same destination with different source");
	check(asciiEngineJson("\"đệ🚀\u007f\"") ==
		"\"\\u0111\\u1ec7\\ud83d\\ude80\\u007f\"", "ASCII JSON transport");
	check(asciiEngineJson("\"\\ud800\"") == "\"\\ud800\"",
		"existing escapes are not re-escaped");
	check(asciiEngineJson("plain ASCII") == "plain ASCII", "ASCII unchanged");
	check(windowsTools().length == 16 &&
		windowsTools().indexOf("llvm-symbolizer.exe") >= 0,
		"exact required tool family");
	check(windowsSystemDlls().join(",") ==
		"advapi32.dll,crypt32.dll,kernel32.dll,ntdll.dll,ole32.dll," +
		"oleaut32.dll,shell32.dll,user32.dll,version.dll,winhttp.dll",
		"exact system allowlist");
	const paths = ["\u{10000}", "é", "z", "\uffff"];
	sortEnginePaths(paths);
	check(paths.join(",") == "z,é,\uffff,\u{10000}", "UTF-8 byte path order");
	if (checks != 98) {
		throw new Error("contract case count changed: " + String(checks));
	}
	console.log("Windows engine contracts: 98 checks OK");
}

when (!testBuild) { main(); }
