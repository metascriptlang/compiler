// Pipeline boundary test: unlike c/*.ms, this must span candidate compiler processes to observe persistent native caches.
import { argv, cwd, env, execFileCapture, exit, platform } from "std/process";
import { chmod, ensureDir, exists, remove, writeFile } from "std/fs";

const windows = platform == "windows";

interface CaseResult {
	name: string;
	expected: string;
	actual: string;
}

interface Ran {
	code: number;
	stdout: string;
}

function scriptArgs(): string[] {
	const rest: string[] = [];
	let seen = false;
	for (const a of argv) {
		if (seen && !a.startsWith("--")) rest.push(a);
		if (a.endsWith("nativeBuildBoundary.ms")) seen = true;
	}
	return rest;
}

function absolute(path: string): string {
	if (path.startsWith("/") || (path.length > 1 && path.charAt(1) == ":")) return path;
	return `${cwd()}/${path}`;
}

const params = scriptArgs();
const compiler = absolute(params.length > 0 ? params[0] : "msc");
const group = params.length > 1 ? params[1] : "all";
if (group != "argv" && group != "compile-cache" && group != "link-cache" && group != "audit" && group != "comptime-cache" && group != "all") {
	console.log("group must be argv, compile-cache, link-cache, audit, comptime-cache, or all");
	exit(2);
}

function makeRoot(): string {
	const base = windows ? "C:/tmp" : "/tmp";
	ensureDir(base);
	let n = performance.now() as int64;
	while (exists(`${base}/msc-native-boundary-${n}`)) n = n + 1;
	const dir = `${base}/msc-native-boundary-${n}`;
	ensureDir(dir);
	return dir;
}

const root = makeRoot();
const results: CaseResult[] = [];

function need(ok: boolean, what: string): void {
	if (ok) return;
	console.log(`boundary: setup step failed: ${what} (root ${root})`);
	exit(1);
}

function put(path: string, content: string): void {
	need(writeFile(path, content).ok, `write ${path}`);
}

function command(dir: string, label: string, exe: string, args: string[]): Ran {
	const r = execFileCapture(exe, args, dir);
	if (r.ok) {
		put(`${dir}/${label}.log`, r.value);
		return { code: 0, stdout: r.value };
	}
	put(`${dir}/${label}.log`, r.error.output + r.error.errorOutput + r.error.message);
	return { code: r.error.exitCode != 0 ? r.error.exitCode : -1, stdout: r.error.output };
}

function fixture(name: string, directives: string, native: string, header: string = "", nativeName: string = "native.c"): string {
	const dir = `${root}/${name}`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/api.h`, "int probeValue(void);\n");
	put(`${dir}/main.ms`, `@include("./api.h");\n${directives}\nextern function probeValue(): int32;\nconsole.log(probeValue());\n`);
	put(`${dir}/${nativeName}`, native);
	put(`${dir}/value.h`, header);
	return dir;
}

function build(dir: string, label: string, output: string = "probe", flags: string[] = [], cc: string = ""): number {
	const args: string[] = ["build", "main.ms"];
	if (cc != "") {
		args.push(`--cc=${cc}`);
	} else if (!windows) {
		args.push("--cc=clang");
	}
	args.push(`--output=${output}`);
	for (const f of flags) args.push(f);
	return command(dir, label, compiler, args).code;
}

function value(dir: string, output: string = "probe"): string {
	const r = execFileCapture(`${dir}/${output}`, []);
	if (!r.ok) {
		need(false, `run ${dir}/${output}`);
		return "";
	}
	return r.value.trim();
}

function record(name: string, expected: string, actual: string): void {
	results.push({ name, expected, actual });
}

function recordTrue(name: string, actual: boolean): void {
	record(name, "true", actual ? "true" : "false");
}

function runCompileCache(): void {
	const source = fixture("source", "@compile(\"./native.c\");", "int probeValue(void) { return 11; }\n");
	need(build(source, "baseline") == 0, "source baseline");
	need(value(source) == "11", "source baseline value");
	put(`${source}/native.c`, "int probeValue(void) { return 22; }\n");
	need(build(source, "source-change") == 0, "source change");
	record("native source edit", "22", value(source));

	const header = fixture("header", "@compile(\"./native.c\");", "#include \"value.h\"\nint probeValue(void) { return VALUE; }\n", "#define VALUE 11\n");
	need(build(header, "baseline") == 0, "header baseline");
	need(value(header) == "11", "header baseline value");
	put(`${header}/value.h`, "#define VALUE 22\n");
	need(build(header, "header-change") == 0, "header change");
	record("native header edit", "22", value(header));
	need(build(header, "new-output", "probe2") == 0, "header new output");
	record("header edit bypassing project cache", "22", value(header, "probe2"));
	need(build(header, "force", "probe2", ["--force"]) == 0, "header force");
	record("header edit with force and global cache", "22", value(header, "probe2"));
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	const uncached = build(header, "uncached-control", "probe2", ["--force"]);
	env.delete("MSC_NO_GLOBAL_CACHE");
	need(uncached == 0, "uncached control");
	record("uncached diagnostic control", "22", value(header, "probe2"));
}

function runLinkCache(): void {
	const archive = fixture("archive", "@link(\"./libnative.a\");", "int probeValue(void) { return 17; }\n");
	for (const label of ["initial", "changed"]) {
		if (label == "changed") put(`${archive}/native.c`, "int probeValue(void) { return 29; }\n");
		need(command(archive, `cc-${label}`, "clang", ["-c", "native.c", "-o", "native.o"]).code == 0, `cc ${label}`);
		need(command(archive, `ar-${label}`, "ar", ["rcs", "libnative.a", "native.o"]).code == 0, `ar ${label}`);
		need(build(archive, label) == 0, `archive ${label}`);
		if (label == "initial") need(value(archive) == "17", "archive initial value");
	}
	record("linked archive replacement", "29", value(archive));

	put(`${archive}/native.c`, "int otherValue(void) { return 31; }\n");
	need(command(archive, "cc-broken", "clang", ["-c", "native.c", "-o", "native.o"]).code == 0, "cc broken");
	need(command(archive, "ar-broken", "ar", ["rcs", "libnative.a", "native.o"]).code == 0, "ar broken");
	const firstFailure = build(archive, "link-failure");
	const secondFailure = build(archive, "link-failure-retry");
	recordTrue("failed link rejects stale output", firstFailure != 0);
	recordTrue("failed link remains invalidated", secondFailure != 0);
}

function makeArchive(dir: string, name: string, result: int32): string {
	put(`${dir}/${name}.c`, `int probeValue(void) { return ${result}; }\n`);
	need(command(dir, `cc-${name}`, "clang", ["-c", `${name}.c`, "-o", `${name}.o`]).code == 0, `cc ${name}`);
	need(command(dir, `ar-${name}`, "ar", ["rcs", `${name}.a`, `${name}.o`]).code == 0, `ar ${name}`);
	return `${dir}/${name}.a`;
}

function homeDir(): string {
	const home = env.get(windows ? "USERPROFILE" : "HOME");
	return home.replaceAll("\\", "/");
}

function writeWrapper(dir: string, toolValue: int32): string {
	if (windows) {
		const wrapper = `${dir}/cc-wrapper.exe`;
		const source = `${dir}/cc-wrapper.c`;
		const zig = `${homeDir()}/.metascript/zig/zig.exe`;
		put(source,
			"#include <process.h>\n#include <stdlib.h>\n"
			+ "int main(int argc, char **argv) {\n"
			+ "  char **args = malloc(sizeof(char *) * (argc + 3));\n"
			+ `  args[0] = "${zig}";\n`
			+ "  args[1] = \"cc\";\n"
			+ `  args[2] = "-DTOOL_VALUE=${toolValue}";\n`
			+ "  for (int i = 1; i < argc; i++) args[i + 2] = argv[i];\n"
			+ "  args[argc + 2] = NULL;\n"
			+ `  return (int)_spawnv(_P_WAIT, "${zig}", (const char * const *)args);\n`
			+ "}\n");
		need(command(dir, `wrapper-${toolValue}`, "gcc", [source, "-o", wrapper]).code == 0, "compile cc wrapper");
		return wrapper;
	}
	const wrapper = `${dir}/cc-wrapper`;
	put(wrapper, `#!/bin/sh\nexec clang -DTOOL_VALUE=${toolValue} "$@"\n`);
	need(chmod(wrapper, 493).ok, "chmod cc wrapper");
	return wrapper;
}

function runAudit(): void {
	const linkOptions = fixture("link options", "", "");
	const firstArchive = makeArchive(linkOptions, "first", 41);
	const secondArchive = makeArchive(linkOptions, "second", 43);
	need(build(linkOptions, "first-link-option", "probe", [`--passL="${firstArchive}"`]) == 0, "first link option");
	need(value(linkOptions) == "41", "first link option value");
	need(build(linkOptions, "second-link-option", "probe", [`--passL="${secondArchive}"`]) == 0, "second link option");
	record("link option change", "43", value(linkOptions));

	const configured = fixture("configured options", "@compile(\"./native.c\");",
		"int probeValue(void) { return TARGET_ARCH + SDK_VERSION + DEPLOYMENT_TARGET; }\n");
	put(`${configured}/build.ms`,
		"const config = { cc: { flags: [\"-DTARGET_ARCH=2\", \"-DSDK_VERSION=17\", \"-DDEPLOYMENT_TARGET=14\"] } };\nexport default config;\n");
	need(build(configured, "first-config") == 0, "first config");
	need(value(configured) == "33", "first config value");
	put(`${configured}/build.ms`,
		"const config = { cc: { flags: [\"-DTARGET_ARCH=4\", \"-DSDK_VERSION=18\", \"-DDEPLOYMENT_TARGET=15\"] } };\nexport default config;\n");
	need(build(configured, "second-config") == 0, "second config");
	record("configured arch SDK and deployment options", "37", value(configured));

	const toolchain = fixture("toolchain", "@compile(\"./native.c\");", "int probeValue(void) { return TOOL_VALUE; }\n");
	const firstWrapper = writeWrapper(toolchain, 47);
	need(build(toolchain, "first-toolchain", "probe", [], firstWrapper) == 0, "first toolchain");
	need(value(toolchain) == "47", "first toolchain value");
	const secondWrapper = writeWrapper(toolchain, 49);
	need(build(toolchain, "second-toolchain", "probe", [], secondWrapper) == 0, "second toolchain");
	record("compiler binary replacement", "49", value(toolchain));

	const mode = fixture("mode", "@compile(\"./native.c\");",
		"#ifdef __OPTIMIZE__\nint probeValue(void) { return 53; }\n#else\nint probeValue(void) { return 51; }\n#endif\n");
	need(build(mode, "debug") == 0, "debug build");
	need(value(mode) == "51", "debug value");
	need(build(mode, "release", "probe", ["--release"]) == 0, "release build");
	record("debug release isolation", "53", value(mode));

	const moved = fixture("moved source", "@compile(\"./native.c\");", "int probeValue(void) { return 59; }\n");
	need(build(moved, "before-remove") == 0, "before remove");
	need(remove(`${moved}/native.c`).ok, "remove native.c");
	recordTrue("removed native source rejects stale output", build(moved, "removed") != 0);
	put(`${moved}/renamed.c`, "int probeValue(void) { return 61; }\n");
	put(`${moved}/main.ms`, "@include(\"./api.h\");\n@compile(\"./renamed.c\");\nextern function probeValue(): int32;\nconsole.log(probeValue());\n");
	need(build(moved, "renamed") == 0, "renamed build");
	record("renamed native source", "61", value(moved));

	const failed = fixture("failed compile", "@compile(\"./native.c\");", "int probeValue(void) { return 67; }\n");
	need(build(failed, "before-failure") == 0, "before failure");
	put(`${failed}/native.c`, "int probeValue(void) { this is not C; }\n");
	const firstFailure = build(failed, "compile-failure");
	const secondFailure = build(failed, "compile-failure-retry");
	recordTrue("failed compile rejects stale output", firstFailure != 0);
	recordTrue("failed compile remains invalidated", secondFailure != 0);
}

function runArgv(): void {
	const spaces = fixture("spaces", "@compile(\"./native.c\");", "int probeValue(void) { return 31; }\n");
	record("executable output path with spaces", "0", `${build(spaces, "output-spaces", "products with spaces/probe")}`);
	const archiveOutput = "products with spaces/libProbe.a";
	const archiveResult = build(spaces, "archive-output-spaces", archiveOutput, ["--app=staticlib"]);
	record("static archive output path with spaces", "0", `${archiveResult}`);
	if (archiveResult == 0) {
		const members = command(spaces, "archive-members", "ar", ["t", archiveOutput]);
		record("static archive retains spaced object path", "0", `${members.code}`);
	}

	const source = fixture("source path", "@compile(\"./native source.c\");", "int probeValue(void) { return 37; }\n", "", "native source.c");
	const sourceResult = build(source, "source-path");
	record("native source path with spaces", "0", `${sourceResult}`);
	if (sourceResult == 0) record("native source path executable", "37", value(source));

	const include = fixture("include path", "@compile(\"./native.c\");\n@passC(\"-I\\\"headers with spaces\\\"\");",
		"#include <value.h>\nint probeValue(void) { return VALUE; }\n");
	ensureDir(`${include}/headers with spaces`);
	put(`${include}/headers with spaces/value.h`, "#define VALUE 41\n");
	const includeResult = build(include, "include-path");
	record("native include path with spaces", "0", `${includeResult}`);
	if (includeResult == 0) record("native include path executable", "41", value(include));

	const quoted = fixture("quoted flag", "@compile(\"./native.c\");\n@passC(\"-DLABEL='\\\"a b\\\"'\");",
		"int probeValue(void) { return sizeof(LABEL); }\n");
	const quotedResult = build(quoted, "quoted-flag");
	record("quoted flag value", "0", `${quotedResult}`);
	if (quotedResult == 0) record("quoted flag value executable", "4", value(quoted));

	const leading = fixture("compiler words", "@compile(\"./native.c\");", "int probeValue(void) { return TOOL_VALUE; }\n");
	const ccWords = windows ? `${homeDir()}/.metascript/zig/zig.exe cc` : "clang";
	const firstWords = build(leading, "compiler-words", "probe", [], `${ccWords} -DTOOL_VALUE=71`);
	record("compiler command with leading arguments", "0", `${firstWords}`);
	if (firstWords == 0) record("compiler command leading argument reaches cc", "71", value(leading));
	const secondWords = build(leading, "compiler-words-changed", "probe", [], `${ccWords} -DTOOL_VALUE=73`);
	record("changed leading argument rebuilds", "0", `${secondWords}`);
	if (secondWords == 0) record("changed leading argument executable", "73", value(leading));
	const libWords = build(leading, "compiler-words-lib", "products/probeLib", ["--app=lib"], `${ccWords} -DTOOL_VALUE=79`);
	record("shared library with leading compiler arguments", "0", `${libWords}`);

	const response = fixture("response file", "@compile(\"./native.c\");", "int probeValue(void) { return 47; }\n");
	const flagPrefix = windows ? "--passL=-LC:/tmp/native-boundary-" : "--passL=-L/tmp/native-boundary-";
	const flagCount: int32 = windows ? 820 : 900;
	const longFlags: string[] = [];
	for (let i: int32 = 0; i < flagCount; i++) longFlags.push(flagPrefix + `${i}`.padStart(4, "0"));
	const responseResult = build(response, "response-file", "products with spaces/response probe", longFlags);
	record("response file preserves arguments", "0", `${responseResult}`);
	if (responseResult == 0) record("response file executable", "47", value(response, "products with spaces/response probe"));
}

function builtValue(dir: string, code: number): string {
	return code == 0 ? value(dir) : "build failed";
}

function comptimeRead(exported: string, name: string, file: string): string {
	return `import { readFile } from "std/fs";\n\n${exported}const ${name}: string = @comptime {\n\tconst r = readFile("${file}");\n\tif (!r.ok) return "missing";\n\treturn r.value;\n};\n`;
}

function comptimeFixture(dir: string): void {
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/lib.ms`, comptimeRead("export ", "SECOND", "second.txt"));
	put(`${dir}/main.ms`, `${comptimeRead("", "FIRST", "first.txt")}import { SECOND } from "./lib";\n\nconsole.log(FIRST + SECOND);\n`);
}

function runComptimeCache(): void {
	const reads = `${root}/comptime`;
	comptimeFixture(reads);
	put(`${reads}/first.txt`, "a");
	put(`${reads}/second.txt`, "b");
	need(build(reads, "baseline") == 0, "comptime baseline");
	need(value(reads) == "ab", "comptime baseline value");
	put(`${reads}/first.txt`, "c");
	record("compile-time read edit in the entry module", "cb", builtValue(reads, build(reads, "entry-read-change")));
	put(`${reads}/second.txt`, "d");
	record("compile-time read edit in an imported module", "cd", builtValue(reads, build(reads, "imported-read-change")));
	need(remove(`${reads}/first.txt`).ok, "remove first.txt");
	record("compile-time read of a removed file", "missingd", builtValue(reads, build(reads, "read-removed")));
	put(`${reads}/first.txt`, "");
	record("compile-time read of a file created empty", "d", builtValue(reads, build(reads, "read-created-empty")));

	const outside = `${root}/comptime-outside`;
	comptimeFixture(`${outside}/app`);
	put(`${outside}/first.txt`, "a");
	put(`${outside}/second.txt`, "b");
	const outsideArgs: string[] = ["build", "app/main.ms", `--output=probe`];
	if (!windows) outsideArgs.push("--cc=clang");
	need(command(outside, "outside-baseline", compiler, outsideArgs).code == 0, "outside baseline");
	need(value(outside) == "ab", "outside baseline value");
	put(`${outside}/first.txt`, "e");
	record("compile-time read edit with the build run outside the source directory", "eb", builtValue(outside, command(outside, "outside-change", compiler, outsideArgs).code));

	const host = `${root}/expansion`;
	ensureDir(`${host}/tool`);
	ensureDir(`${host}/pkg/src`);
	ensureDir(`${host}/app`);
	put(`${host}/app/build.ms`, "const config = {};\nexport default config;\n");
	put(`${host}/tool/text.ms`, "import { Node, NodeKind, stringValue, expansionFile } from \"std/meta\";\nimport { readFile } from \"std/fs\";\nimport { dirname, join } from \"std/fs/path\";\n\nexport macro includeText(p: Node): Node {\n\tconst r = readFile(join(dirname(expansionFile()), stringValue(p)));\n\treturn { kind: NodeKind.StringLiteral, line: p.line, column: p.column, value: r.ok ? r.value : \"missing\" };\n}\n");
	put(`${host}/pkg/src/greet.ms`, "import { includeText } from \"../../tool/text\";\n\nexport const GREETING: string = includeText(\"./greeting.txt\");\n");
	put(`${host}/pkg/src/greeting.txt`, "hi");
	put(`${host}/app/main.ms`, "import { expansionFile } from \"std/meta\";\nimport { GREETING } from \"../pkg/src/greet\";\n\nconst SELF: string = @comptime { return expansionFile(); };\nconsole.log(GREETING + \":\" + (SELF.endsWith(\"/app/main.ms\") ? \"self\" : SELF));\n");
	record("macro reads a file beside its expansion site", "hi:self", builtValue(`${host}/app`, build(`${host}/app`, "expansion-first")));
	put(`${host}/pkg/src/greeting.txt`, "yo");
	record("macro read beside its expansion site after an edit", "yo:self", builtValue(`${host}/app`, build(`${host}/app`, "expansion-change")));

	const branch = `${root}/define-branch`;
	ensureDir(branch);
	put(`${branch}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${branch}/main.ms`, "when (tier == 2) {\n\tconsole.log(\"two\");\n} else {\n\tconsole.log(\"other\");\n}\n");
	need(build(branch, "branch-first", "probe", ["-d:tier=1"]) == 0, "define branch baseline");
	need(value(branch) == "other", "define branch baseline value");
	record("when branch after a -d: value change", "two", builtValue(branch, build(branch, "branch-change", "probe", ["-d:tier=2"])));

	const defines = `${root}/defines`;
	ensureDir(defines);
	put(`${defines}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${defines}/main.ms`, "import { define } from \"std/meta\";\n\nconst OUT: string = @comptime { return define(\"probeOut\"); };\nwhen (tier == 2) {\n\tconsole.log(\"two:\" + OUT);\n} else {\n\tconsole.log(\"other:\" + OUT);\n}\n");
	record("build with -d:tier=1 -d:probeOut=x", "other:x", builtValue(defines, build(defines, "define-first", "probe", ["-d:tier=1", "-d:probeOut=x"])));
	record("build with -d:tier=2 -d:probeOut=x", "two:x", builtValue(defines, build(defines, "define-when-change", "probe", ["-d:tier=2", "-d:probeOut=x"])));
	record("build with -d:tier=2 -d:probeOut=y", "two:y", builtValue(defines, build(defines, "define-value-change", "probe", ["-d:tier=2", "-d:probeOut=y"])));
	record("build with -d:tier=2", "two:", builtValue(defines, build(defines, "define-removed", "probe", ["-d:tier=2"])));
}

if (group == "argv" || group == "all") runArgv();
if (group == "compile-cache" || group == "all") runCompileCache();
if (group == "link-cache" || group == "all") runLinkCache();
if (group == "audit" || group == "all") runAudit();
if (group == "comptime-cache" || group == "all") runComptimeCache();

let failures = 0;
console.log(`root ${root}`);
for (const r of results) {
	const pass = r.expected == r.actual;
	if (!pass) failures = failures + 1;
	console.log(`${pass ? "pass" : "FAIL"}  ${r.name}  expected=${r.expected} actual=${r.actual}`);
}
exit(failures == 0 ? 0 : 1);
