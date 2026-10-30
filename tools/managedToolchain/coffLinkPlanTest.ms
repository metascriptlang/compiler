import { CoffLinkPlan, parseCoffLinkArguments } from "./coffLinkPlan";

let cases: int32 = 0;

function expected(
	base: uint64 = 1, machine: string = "X64", dll: boolean = false,
	stack: uint64 | null = null, inputs: string[] = [],
	notCarried: string[] = [],
): CoffLinkPlan {
	return { base, machine, dll, stack, inputs, notCarried };
}

function sameStrings(actual: string[], wanted: string[]): boolean {
	if (actual.length != wanted.length) { return false; }
	for (let i: int32 = 0; i < wanted.length; i += 1) {
		if (actual[i] != wanted[i]) { return false; }
	}
	return true;
}

function accepted(tokens: string[], wanted: CoffLinkPlan): void {
	const result = parseCoffLinkArguments(tokens, "fixture.o");
	if (!result.ok) { throw new Error(result.error); }
	const actual = result.value;
	if (actual.base != wanted.base || actual.machine != wanted.machine ||
		actual.dll != wanted.dll || actual.stack != wanted.stack ||
		!sameStrings(actual.inputs, wanted.inputs) ||
		!sameStrings(actual.notCarried, wanted.notCarried)) {
		throw new Error("COFF linker plan differs");
	}
	cases += 1;
}

function refused(
	tokens: string[], fragment: string, objectName: string = "fixture.o",
): void {
	const result = parseCoffLinkArguments(tokens, objectName);
	if (result.ok || result.error.indexOf(fragment) < 0) {
		throw new Error("expected COFF refusal containing: " + fragment);
	}
	cases += 1;
}

function run(): void {
	refused([], "linker");
	refused([""], "tokens[0]");
	refused(["lld\0-link"], "tokens[0]");
	refused(["lld-link"], "fixture.o 0 times");
	refused(["lld-link", "fixture.o"], "-BASE");
	refused(["lld-link", "-BASE:1", "fixture.o"], "-MACHINE");
	refused(["lld-link", "-MACHINE:X64", "fixture.o"], "-BASE");
	accepted(["lld-link", "-BASE:1", "-MACHINE:X64", "fixture.o"], expected());
	accepted(["C:/tools/lld-link", "fixture.o", "-MACHINE:X64", "-BASE:1"],
		expected());
	accepted(["lld-link", "-BASE:0", "-MACHINE:ARM64", "-DLL", "fixture.o"],
		expected(0, "ARM64", true));
	accepted(["lld-link", "-BASE:1", "-MACHINE:X64", "-STACK:0", "fixture.o"],
		expected(1, "X64", false, 0));
	accepted(["lld-link", "-BASE:00001", "-MACHINE:X64", "fixture.o"],
		expected());
	accepted(["lld-link", "-BASE:000000000000000000000000000001",
		"-MACHINE:X64", "fixture.o"], expected());
	const full: uint64 = 18446744073709551615;
	accepted(["lld-link", "-BASE:18446744073709551615", "-MACHINE:X64",
		"fixture.o"], expected(full));
	accepted(["lld-link", "-BASE:1", "-MACHINE:X64",
		"-STACK:18446744073709551615", "fixture.o"],
		expected(1, "X64", false, full));
	accepted(["lld-link", "-BASE:9007199254740993", "-MACHINE:X64",
		"fixture.o"], expected(9007199254740993));
	accepted(["lld-link", "-BASE:9223372036854775808", "-MACHINE:X64",
		"fixture.o"], expected(9223372036854775808));
	accepted(["lld-link", "-BASE:1", "-BASE:2", "-MACHINE:X64", "fixture.o"],
		expected(2));
	accepted(["lld-link", "-BASE:1", "-MACHINE:X64", "-MACHINE:ARM64",
		"-STACK:1", "-STACK:2", "-DLL", "-DLL", "fixture.o"],
		expected(1, "ARM64", true, 2));
	accepted(["lld-link", "-BASE:1", "-MACHINE:Other", "fixture.o"],
		expected(1, "Other"));
	for (const flag of [
		"-lldmingw", "-ERRORLIMIT:0", "-NOLOGO", "-DEBUG", "-BUILD-ID:NO",
		"-BREPRO", "-MLLVM:-float-abi=hard",
	]) {
		accepted(["lld-link", flag, "-BASE:1", "-MACHINE:X64", "fixture.o"],
			expected());
	}
	for (const prefix of ["-PDB:", "-PDBALTPATH:", "-OUT:", "-IMPLIB:"]) {
		accepted(["lld-link", prefix + "a file.tmp", "-BASE:1", "-MACHINE:X64",
			"fixture.o"], expected());
		accepted(["lld-link", prefix, "-BASE:1", "-MACHINE:X64", "fixture.o"],
			expected());
	}
	const alias = "-ALTERNATENAME:weak=fallback";
	accepted(["lld-link", alias, "-BASE:1", "-MACHINE:X64", "fixture.o", alias],
		expected(1, "X64", false, null, [], [alias, alias]));
	accepted(["lld-link", "-ALTERNATENAME:", "-BASE:1", "-MACHINE:X64",
		"fixture.o"], expected(1, "X64", false, null, [], ["-ALTERNATENAME:"]));
	accepted(["lld-link", "-BASE:1", "-MACHINE:X64", "dir/fixture.o",
		"crt2.obj", "libc.lib", "libc.lib", "é日本🚀/lib.lib"],
		expected(1, "X64", false, null,
			["crt2.obj", "libc.lib", "libc.lib", "é日本🚀/lib.lib"]));
	accepted(["lld-link", "-BASE:1", "-MACHINE:X64", "fixture.o",
		"../outside/missing.lib"],
		expected(1, "X64", false, null, ["../outside/missing.lib"]));
	refused(["lld-link", "crt2.obj", "fixture.o"], "before the fixture");
	refused(["lld-link", "fixture.o", "fixture.o"], "fixture.o 2 times");
	refused(["lld-link", "fixture.o", "dir/fixture.o", "crt2.obj"],
		"before the fixture");
	refused(["lld-link", "-BASE:1", "-MACHINE:X64", ""], "tokens[3]");
	refused(["lld-link", "-BASE:1", "-MACHINE:X64", "fixture.o", "a\0b"],
		"tokens[4]");
	refused(["lld-link", "fixture.o"], "object name", "");
	refused(["lld-link", "fixture.o"], "object name", "a\0b");
	refused(["lld-link", "-MACHINE:", "fixture.o"], "-MACHINE value is empty");
	for (const flag of [
		"-unknown", "-dll", "-machine:X64", "-MLLVM:-float-abi=soft",
		"-BASE:", "-BASE:-1", "-BASE:+1", "-BASE:0x10", "-BASE:1.0",
		"-BASE:١", "-STACK:", "-STACK:-1", "-STACK:1x",
	]) { refused(["lld-link", flag, "fixture.o"], "not understood"); }
	for (const flag of [
		"-BASE:18446744073709551616", "-STACK:18446744073709551616",
		"-BASE:99999999999999999999999999999999999999999999999999",
	]) { refused(["lld-link", flag, "fixture.o"], "uint64"); }
	const tokens = ["lld-link", "-BASE:1", "-MACHINE:X64", "fixture.o", "a.lib"];
	const result = parseCoffLinkArguments(tokens, "fixture.o");
	if (!result.ok || tokens[4] != "a.lib") {
		throw new Error("COFF parsing mutated its tokens");
	}
	tokens[4] = "other.lib";
	if (result.value.inputs[0] != "a.lib") {
		throw new Error("COFF inputs alias the token array");
	}
	cases += 1;
	console.log("COFF linker plans: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
