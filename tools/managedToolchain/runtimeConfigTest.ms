import {
	configLine, renderRuntimeConfig, RuntimeConfigInput,
} from "./runtimeConfig";
import { ElfLinkItemKind } from "./elfLinkPlan";

let cases: int32 = 0;

function expectLine(tokens: string[], expected: string): void {
	const result = configLine(tokens);
	if (!result.ok || result.value != expected) {
		throw new Error("config line changed");
	}
	cases += 1;
}

function baseInput(): RuntimeConfigInput {
	return {
		target: "wasm32-wasi", directory: "", llvmMajor: "22",
		engineRelative: "../engine",
		spec: { clangTarget: "wasm32-wasip1", linker: "wasm-ld",
			driverFlags: ["-nostdlib"], sysroot: false },
		compile: { target: "wasm32-unknown-wasi", cpu: "lime1",
			features: ["-atomics", "+sign-ext"], pic: ["-fno-PIE", "-fno-PIC"],
			defines: [], isystem: ["/private/seed/include"] },
		includeDirectories: ["wasm-wasi-musl", "generic-musl"],
		items: [
			{ kind: ElfLinkItemKind.Argument, value: "--entry" },
			{ kind: ElfLinkItemKind.Argument, value: "_start" },
			{ kind: ElfLinkItemKind.InputPath, value: "/cache/crt1-command.o" },
			{ kind: ElfLinkItemKind.UserObject, value: "" },
			{ kind: ElfLinkItemKind.InputPath, value: "/cache/libc.a" },
		],
	};
}

function rendered(input: RuntimeConfigInput): string {
	const result = renderRuntimeConfig(input);
	if (!result.ok) { throw new Error(result.error); }
	return result.value;
}

function refused(input: RuntimeConfigInput): void {
	if (renderRuntimeConfig(input).ok) {
		throw new Error("unsafe config text was accepted");
	}
	cases += 1;
}

function run(): void {
	expectLine([], "");
	expectLine(["-Xlinker", "<CFGDIR>/t/libc.a"],
		"-Xlinker <CFGDIR>/t/libc.a");
	expectLine(["AZaz09_.+=:/<>,@%-"], "AZaz09_.+=:/<>,@%-");
	for (const token of [
		"a b", "a\"b", "a'b", "a\\b", "a;b", "$HOME", "", "a\tb",
		"a\rb", "a\nb", "a\0b", "é", "🚀", "[x]",
	]) {
		if (configLine([token]).ok) { throw new Error("unsafe token accepted"); }
		cases += 1;
	}
	const expected = [
		"-target wasm32-wasip1",
		"-Xclang -target-cpu -Xclang lime1",
		"-Xclang -target-feature -Xclang -atomics",
		"-Xclang -target-feature -Xclang +sign-ext",
		"-fno-PIE -fno-PIC",
		"-nostdinc",
		"-isystem <CFGDIR>/../engine/lib/clang/22/include",
		"-isystem <CFGDIR>/include/libc/wasm-wasi-musl",
		"-isystem <CFGDIR>/include/libc/generic-musl",
		"-nostdlib",
		"--ld-path=<CFGDIR>/../engine/bin/wasm-ld",
		"-Xlinker -L -Xlinker <CFGDIR>/wasm32-wasi",
		"-Xlinker --entry",
		"-Xlinker _start",
		"-Xlinker <CFGDIR>/wasm32-wasi/crt1-command.o",
		"-Xlinker <CFGDIR>/wasm32-wasi/libc.a",
	].join("\n") + "\n";
	if (rendered(baseInput()) != expected) {
		throw new Error("WASI cfg changed");
	}
	cases += 1;
	for (const target of ["x86_64-linux-gnu.2.31", "aarch64-linux-gnu.2.31",
		"x86_64-linux-musl", "aarch64-linux-musl", "x86_64-freebsd.14.0",
		"aarch64-freebsd.14.0"]) {
		let request = baseInput();
		request.target = target;
		request.directory = target + ".shared";
		request.spec.sysroot = true;
		request.spec.clangTarget = "";
		request.spec.linker = "ld.lld";
		request.spec.driverFlags = ["-nostdlib", "-no-pie"];
		request.compile.defines = ["-D__GLIBC_MINOR__=31"];
		const text = rendered(request);
		if (!text.startsWith("-target wasm32-unknown-wasi\n") ||
			text.indexOf("--sysroot=<CFGDIR>/" + target + ".shared\n") < 0 ||
			text.indexOf("-D__GLIBC_MINOR__=31\n") < 0 ||
			text.indexOf("-no-pie\n") < 0 ||
			text.indexOf("--ld-path=<CFGDIR>/../engine/bin/ld.lld\n") < 0 ||
			text.indexOf("-Xlinker <CFGDIR>/" + target + ".shared/libc.a\n") < 0 ||
			text.indexOf("/private/seed") >= 0) {
			throw new Error("profile/directory policy changed for " + target);
		}
		cases += 1;
	}
	let duplicates = baseInput();
	duplicates.compile.features = ["+sse4.2", "+sse4.2"];
	duplicates.items = [
		{ kind: ElfLinkItemKind.InputPath, value: "/cache/lib.a" },
		{ kind: ElfLinkItemKind.UserObject, value: "" },
		{ kind: ElfLinkItemKind.InputPath, value: "/other/lib.a" },
		{ kind: ElfLinkItemKind.Argument, value: "--defsym=x=1,y=2" },
	];
	const repeated = rendered(duplicates);
	if (repeated.indexOf("-Xclang -target-feature -Xclang +sse4.2\n" +
		"-Xclang -target-feature -Xclang +sse4.2\n") < 0 ||
		repeated.indexOf("-Xlinker <CFGDIR>/wasm32-wasi/lib.a\n" +
		"-Xlinker <CFGDIR>/wasm32-wasi/lib.a\n" +
		"-Xlinker --defsym=x=1,y=2\n") < 0) {
		throw new Error("order, duplicates, commas or user-object elision changed");
	}
	cases += 1;
	let minimal = baseInput();
	minimal.compile.features = [];
	minimal.compile.pic = [];
	minimal.compile.defines = [];
	minimal.includeDirectories = [];
	minimal.spec.driverFlags = [];
	minimal.items = [];
	const plain = rendered(minimal);
	if (plain.indexOf("target-feature") >= 0 || plain.indexOf("\n\n") >= 0 ||
		!plain.endsWith("\n")) { throw new Error("empty optional groups changed"); }
	cases += 1;
	for (const bad of ["has space.o", "x,y.a", "x@y.o", ".", "..", "a\0b.o"]) {
		let request = baseInput();
		request.items = [{ kind: ElfLinkItemKind.InputPath, value: bad }];
		refused(request);
	}
	let bad = baseInput(); bad.compile.cpu = "two words"; refused(bad);
	bad = baseInput(); bad.compile.features = ["+bad feature"]; refused(bad);
	bad = baseInput(); bad.compile.pic = ["a;b"]; refused(bad);
	bad = baseInput(); bad.compile.defines = ["-DBAD='x'"]; refused(bad);
	bad = baseInput(); bad.includeDirectories = ["bad directory"]; refused(bad);
	bad = baseInput(); bad.engineRelative = "$HOME"; refused(bad);
	bad = baseInput(); bad.llvmMajor = "2 3"; refused(bad);
	bad = baseInput(); bad.spec.linker = "ld lld"; refused(bad);
	bad = baseInput(); bad.spec.clangTarget = "bad target"; refused(bad);
	bad = baseInput(); bad.spec.driverFlags = ["-Wl;bad"]; refused(bad);
	bad = baseInput(); bad.directory = "bad directory"; refused(bad);
	console.log("runtime configs: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
