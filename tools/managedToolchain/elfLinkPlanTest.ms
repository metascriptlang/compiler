import {
	ElfLinkItem,
	ElfLinkItemKind,
	parseElfLinkArguments,
} from "./elfLinkPlan";

let cases: int32 = 0;

function argument(value: string): ElfLinkItem {
	return { kind: ElfLinkItemKind.Argument, value };
}

function input(value: string): ElfLinkItem {
	return { kind: ElfLinkItemKind.InputPath, value };
}

function user(): ElfLinkItem {
	return { kind: ElfLinkItemKind.UserObject, value: "" };
}

function accepted(
	tokens: string[],
	expected: ElfLinkItem[],
	output: string = "result",
): void {
	const result = parseElfLinkArguments(tokens, output, "fixture.o");
	if (!result.ok) { throw new Error(result.error); }
	const plan = result.value;
	if (plan.linker != "ld.lld" || plan.items.length != expected.length) {
		throw new Error("linker basename or item count changed");
	}
	for (let i: int32 = 0; i < expected.length; i += 1) {
		if (plan.items[i].kind != expected[i].kind ||
			plan.items[i].value != expected[i].value) {
			throw new Error("link item changed at " + String(i));
		}
	}
	cases += 1;
}

function refused(
	tokens: string[],
	fragment: string,
	output: string = "result",
	objectName: string = "fixture.o",
): void {
	const result = parseElfLinkArguments(tokens, output, objectName);
	if (result.ok || result.error.indexOf(fragment) < 0) {
		throw new Error("expected link refusal containing: " + fragment);
	}
	cases += 1;
}

function run(): void {
	refused([], "linker");
	refused([""], "tokens[0]");
	refused(["ld\0.lld"], "tokens[0]");
	refused(["ld.lld"], "fixture.o 0 times");
	accepted(["ld.lld", "fixture.o"], [user()]);
	accepted(["/tools/ld.lld", "fixture.o"], [user()]);
	accepted(["C:/tools/ld.lld", "fixture.o"], [user()]);
	accepted(["ld.lld", "/cache/fixture.o"], [user()]);
	accepted(["ld.lld", "sub/fixture.o"], [user()]);
	accepted(["ld.lld", "fixture.o", "-o", "result"], [user()]);
	accepted(["ld.lld", "-o", "result", "fixture.o"], [user()]);
	accepted(["ld.lld", "-o", "result", "fixture.o", "-o", "result"],
		[user()]);
	accepted(["ld.lld", "fixture.o", "-o", "-dash"], [user()], "-dash");
	refused(["ld.lld", "fixture.o", "-o"], "tokens[2]");
	refused(["ld.lld", "fixture.o", "-o", "other"], "not result");
	refused(["ld.lld", "-o", "other", "fixture.o"], "not result");
	refused(["ld.lld", "fixture.o", "-o", ""], "tokens[3]");
	refused(["ld.lld", "fixture.o", "-o", "result", "-o", "other"],
		"not result");
	refused(["ld.lld", "fixture.o"], "output", "");
	refused(["ld.lld", "fixture.o"], "output", "result\0suffix");
	refused(["ld.lld", "fixture.o"], "object name", "result", "");
	refused(["ld.lld", "fixture.o"], "object name", "result", "a\0b.o");
	refused(["ld.lld", "fixture.o", "fixture.o"], "fixture.o 2 times");
	refused(["ld.lld", "/one/fixture.o", "/two/fixture.o"],
		"fixture.o 2 times");
	refused(["ld.lld", "other.o"], "fixture.o 0 times");
	refused(["ld.lld", ""], "tokens[1]");
	refused(["ld.lld", "fixture.o", "bad\0input"], "tokens[2]");
	for (const flag of ["-z", "--entry", "-m", "--dynamic-linker", "-mllvm"]) {
		accepted(["ld.lld", "fixture.o", flag, "value"],
			[user(), argument(flag), argument("value")]);
		accepted(["ld.lld", flag, "fixture.o", "fixture.o"],
			[argument(flag), argument("fixture.o"), user()]);
		refused(["ld.lld", "fixture.o", flag], "tokens[2]");
		refused(["ld.lld", "fixture.o", flag, ""], "tokens[3]");
		refused(["ld.lld", flag, "fixture.o"], "fixture.o 0 times");
	}
	accepted(["ld.lld", "-z", "-o", "fixture.o"],
		[argument("-z"), argument("-o"), user()]);
	accepted(["ld.lld", "--as-needed", "-L/cache", "fixture.o", "--gc-sections"],
		[argument("--as-needed"), argument("-L/cache"), user(),
			argument("--gc-sections")]);
	accepted(["ld.lld", "crt1.o", "fixture.o", "libc.a", "libc.a"],
		[input("crt1.o"), user(), input("libc.a"), input("libc.a")]);
	accepted(["ld.lld", "fixture.o", "../outside/libc.a", "/missing/libm.a"],
		[user(), input("../outside/libc.a"), input("/missing/libm.a")]);
	accepted(["ld.lld", "fixture.o", "-o", "a result"], [user()], "a result");
	accepted(["ld.lld", "fixture.o", "é日本🚀/lib.a"],
		[user(), input("é日本🚀/lib.a")]);
	accepted(["ld.lld", "--entry=main", "fixture.o", "-melf_x86_64"],
		[argument("--entry=main"), user(), argument("-melf_x86_64")]);
	const tokens = ["ld.lld", "fixture.o", "relative/lib.a"];
	const result = parseElfLinkArguments(tokens, "result", "fixture.o");
	if (!result.ok || tokens[0] != "ld.lld" || tokens[1] != "fixture.o" ||
		tokens[2] != "relative/lib.a") {
		throw new Error("link parsing mutated its input");
	}
	tokens[2] = "changed/lib.a";
	if (result.value.items[1].value != "relative/lib.a") {
		throw new Error("plan retained the mutable token array");
	}
	cases += 1;
	console.log("ELF linker plans: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
