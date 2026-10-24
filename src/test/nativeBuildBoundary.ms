// Pipeline boundary test: unlike c/*.ms, this must span candidate compiler processes to observe persistent native caches.
import { argv, cwd, env, execFileCapture, exit, platform } from "std/process";
import { appendFile, chmod, copyFile, ensureDir, exists, readFile, remove, removeAll, writeFile } from "std/fs";

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
	return argv.slice(1).filter((a: string): boolean => !a.startsWith("--"));
}

function absolute(path: string): string {
	if (path.startsWith("/") || (path.length > 1 && path.charAt(1) == ":")) return path;
	return `${cwd()}/${path}`;
}

const params = scriptArgs();
const compiler = absolute(params.length > 0 ? params[0] : "msc");
const group = params.length > 1 ? params[1] : "all";
if (group != "argv" && group != "compile-cache" && group != "link-cache" && group != "audit" && group != "comptime-cache" && group != "object-store" && group != "project-cache" && group != "directive-paths" && group != "spawn-drain" && group != "upcast-cast" && group != "emcc-argv-fs" && group != "emcc-watch-process" && group != "emcc-jspi" && group != "module-names" && group != "wasi-platform" && group != "ios-process" && group != "all") {
	console.log("group must be argv, compile-cache, link-cache, audit, comptime-cache, object-store, project-cache, directive-paths, spawn-drain, upcast-cast, emcc-argv-fs, emcc-watch-process, emcc-jspi, module-names, wasi-platform, ios-process, or all");
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

function includedFixture(name: string, header: string): string {
	const dir = `${root}/${name}`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/main.ms`, "@include(\"./value.h\");\nextern function probeValue(): int32;\nconsole.log(probeValue());\n");
	put(`${dir}/value.h`, header);
	return dir;
}

function waitForNextSecond(): void {
	const until = performance.now() + 2000;
	while (performance.now() < until) execFileCapture(compiler, ["--version"]);
}

function build(dir: string, label: string, output: string = "probe", flags: string[] = [], cc: string = "", exe: string = compiler): number {
	const args: string[] = ["build", "main.ms"];
	if (cc != "") {
		args.push(`--cc=${cc}`);
	} else if (!windows) {
		args.push("--cc=clang");
	}
	args.push(`--output=${output}`);
	for (const f of flags) args.push(f);
	return command(dir, label, exe, args).code;
}

function twinCompiler(): string {
	const stem = compiler.endsWith(".exe") ? compiler.slice(0, compiler.length - 4) : compiler;
	const twin = windows ? `${stem}Twin.exe` : `${stem}Twin`;
	need(copyFile(compiler, twin).ok, `copy ${compiler} to ${twin}`);
	need(appendFile(twin, "\n").ok, `append to ${twin}`);
	if (!windows) need(chmod(twin, 493).ok, `chmod ${twin}`);
	return twin;
}

function recompiledObjects(dir: string, label: string): string {
	const log = readFile(`${dir}/${label}.log`);
	if (!log.ok) return "no log";
	let n = 0;
	for (const line of log.value.split("\n")) {
		const compileLine = line.indexOf("  cc ", 0) >= 0 || line.indexOf("  @compile ", 0) >= 0;
		const reused = line.indexOf("cached", 0) >= 0 || line.indexOf("(stored)", 0) >= 0;
		if (compileLine && line.indexOf(" → ", 0) >= 0 && !reused) n = n + 1;
	}
	return `${n}`;
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

	const included = includedFixture("included", "#define VALUE 11\nstatic inline int probeValue(void) { return VALUE; }\n");
	waitForNextSecond();
	need(build(included, "baseline") == 0, "included baseline");
	need(value(included) == "11", "included baseline value");
	put(`${included}/value.h`, "#define VALUE 22\nstatic inline int probeValue(void) { return VALUE; }\n");
	need(build(included, "header-change") == 0, "included header change");
	record("module-included header edit", "22", value(included));
	need(build(included, "new-output", "probe2") == 0, "included new output");
	record("module-included header edit bypassing project cache", "22", value(included, "probe2"));

	const nested = includedFixture("nested", "#include \"deep.h\"\nstatic inline int probeValue(void) { return DEEP; }\n");
	put(`${nested}/deep.h`, "#define DEEP 11\n");
	waitForNextSecond();
	need(build(nested, "baseline") == 0, "nested baseline");
	need(value(nested) == "11", "nested baseline value");
	put(`${nested}/deep.h`, "#define DEEP 33\n");
	need(build(nested, "header-change", "probe2") == 0, "nested header change");
	record("transitively included header edit", "33", value(nested, "probe2"));

	const twinned = includedFixture("twin", "static inline int probeValue(void) { return 44; }\n");
	waitForNextSecond();
	need(build(twinned, "first") == 0, "twin first build");
	const twin = twinCompiler();
	const twinBuilt = build(twinned, "twin", "probe2", ["--verbose"], "", twin);
	remove(twin);
	need(twinBuilt == 0, "twin build");
	record("a compiler one byte apart reuses every object", "0", recompiledObjects(twinned, "twin"));
	record("twin build output", "44", value(twinned, "probe2"));
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

	const cliArchive = fixture("cli-archive", "", "int probeValue(void) { return 17; }\n");
	for (const label of ["initial", "changed"]) {
		if (label == "changed") put(`${cliArchive}/native.c`, "int probeValue(void) { return 29; }\n");
		need(command(cliArchive, `cc-${label}`, "clang", ["-c", "native.c", "-o", "native.o"]).code == 0, `cc cli ${label}`);
		need(command(cliArchive, `ar-${label}`, "ar", ["rcs", "libnative.a", "native.o"]).code == 0, `ar cli ${label}`);
		need(build(cliArchive, label, "probe", ["--link=libnative.a"]) == 0, `cli archive ${label}`);
		if (label == "initial") need(value(cliArchive) == "17", "cli archive initial value");
	}
	record("archive given by --link replaced", "29", value(cliArchive));

	const cliObject = fixture("cli-object", "", "int probeValue(void) { return 5; }\n");
	need(command(cliObject, "cc-object", "clang", ["-c", "native.c", "-o", "native.o"]).code == 0, "cc cli object");
	put(`${cliObject}/extra.c`, "int extraValue(void) { return 40; }\n");
	need(command(cliObject, "cc-extra", "clang", ["-c", "extra.c", "-o", "extra.o"]).code == 0, "cc cli extra");
	need(command(cliObject, "ar-extra", "ar", ["rcs", "libextra.a", "extra.o"]).code == 0, "ar cli extra");
	put(`${cliObject}/build.ms`, "const config = { cc: { linkFlags: [\"libextra.a\"] }, globalImports: [\"./g\"] };\nexport default config;\n");
	put(`${cliObject}/g.ms`, "export const offset = 100;\n");
	put(`${cliObject}/api.h`, "int probeValue(void);\nint extraValue(void);\n");
	put(`${cliObject}/main.ms`, "@include(\"./api.h\");\nextern function probeValue(): int32;\nextern function extraValue(): int32;\nconsole.log(probeValue() + extraValue() + offset);\n");
	need(build(cliObject, "cli-object", "probe", ["--link=native.o"]) == 0, "cli object with build.ms");
	record("object given by --link keeps build.ms linkFlags and globalImports", "145", value(cliObject));

	if (windows) {
		const resource = fixture("cli-resource", "@compile(\"./native.c\");", "int probeValue(void) { return 1; }\n");
		for (const name of ["AlphaOne", "BravoTwo"]) {
			put(`${resource}/version.rc`, `1 VERSIONINFO\nFILEVERSION 1,2,3,4\nBEGIN\n  BLOCK "StringFileInfo"\n  BEGIN\n    BLOCK "040904B0"\n    BEGIN\n      VALUE "ProductName", "${name}"\n    END\n  END\n  BLOCK "VarFileInfo"\n  BEGIN\n    VALUE "Translation", 0x409, 1200\n  END\nEND\n`);
			need(command(resource, `rc-${name}`, "zig", ["rc", "/fo", "version.res", "version.rc"]).code == 0, `zig rc ${name}`);
			need(build(resource, name, "probe", ["--link=version.res"]) == 0, `cli resource ${name}`);
			if (name == "AlphaOne") need(holdsUtf16(`${resource}/probe`, "AlphaOne"), "cli resource initial product name");
		}
		recordTrue("resource given by --link replaced", holdsUtf16(`${resource}/probe`, "BravoTwo") && !holdsUtf16(`${resource}/probe`, "AlphaOne"));
	}
	if (!windows) runLinkOrder();
}

function holdsUtf16(path: string, text: string): boolean {
	const content = readFile(path);
	if (!content.ok) return false;
	let wide = "";
	for (let i = 0; i < text.length; i++) wide = wide + text.charAt(i) + "\u0000";
	return content.value.byteIndexOf(wide, 0) >= 0;
}

function firstLinkedWeakProbeWins(result: int32, edit: string): string {
	return `__attribute__((weak)) int probeValue(void) { return ${result}; }\n// ${edit}\n`;
}

function runLinkOrder(): void {
	const order = fixture("link-order", "@compile(\"./first.c\");\n@compile(\"./second.c\");\n@compile(\"./third.c\");", firstLinkedWeakProbeWins(1, "initial"), "", "first.c");
	put(`${order}/second.c`, firstLinkedWeakProbeWins(2, "initial"));
	put(`${order}/third.c`, firstLinkedWeakProbeWins(3, "initial"));
	need(build(order, "order-initial") == 0, "link order initial");
	need(value(order) == "1", "link order initial value");
	put(`${order}/first.c`, firstLinkedWeakProbeWins(1, "first edited"));
	need(build(order, "order-first-edited") == 0, "link order first edited");
	record("an edited first native source keeps its place in the link", "1", value(order));
	put(`${order}/first.c`, firstLinkedWeakProbeWins(1, "first and second edited"));
	put(`${order}/second.c`, firstLinkedWeakProbeWins(2, "first and second edited"));
	need(build(order, "order-two-edited") == 0, "link order two edited");
	record("two edited native sources before a cached one keep their place in the link", "1", value(order));
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

function windowsDriverQuoter(): string {
	return `
static char* quoteArgument(const char* arg) {
  int special = arg[0] == 0;
  for (const char* s = arg; *s; s++) {
    if (*s == ' ' || *s == '\\t' || *s == '"') special = 1;
  }
  if (!special) return (char*)arg;
  char* buffer = (char*)malloc(strlen(arg) * 2 + 3);
  if (!buffer) abort();
  char* out = buffer;
  *out++ = '"';
  for (const char* s = arg; *s; s++) {
    if (*s == '\\\\') {
      int count = 0;
      while (*s == '\\\\') { count++; s++; }
      if (*s == 0) {
        for (int i = 0; i < count * 2; i++) *out++ = '\\\\';
        break;
      }
      if (*s == '"') {
        for (int i = 0; i < count * 2 + 1; i++) *out++ = '\\\\';
      } else {
        for (int i = 0; i < count; i++) *out++ = '\\\\';
      }
      *out++ = *s;
    } else {
      if (*s == '"') *out++ = '\\\\';
      *out++ = *s;
    }
  }
  *out++ = '"';
  *out = 0;
  return buffer;
}
`;
}

function writeWrapper(dir: string, toolValue: int32): string {
	if (windows) {
		const wrapper = `${dir}/cc-wrapper.exe`;
		const source = `${dir}/cc-wrapper.c`;
		const zig = `${homeDir()}/.metascript/zig/zig.exe`;
		put(source,
			"#include <process.h>\n#include <stdlib.h>\n#include <string.h>\n"
			+ windowsDriverQuoter()
			+ "int main(int argc, char **argv) {\n"
			+ "  char **args = malloc(sizeof(char *) * (argc + 3));\n"
			+ `  args[0] = quoteArgument("${zig}");\n`
			+ "  args[1] = \"cc\";\n"
			+ `  args[2] = "-DTOOL_VALUE=${toolValue}";\n`
			+ "  for (int i = 1; i < argc; i++) args[i + 2] = quoteArgument(argv[i]);\n"
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

function projectDriver(dir: string): string {
	if (windows) {
		const wrapper = `${dir}/project-cc.exe`;
		const source = `${dir}/project-cc.c`;
		const zig = `${homeDir()}/.metascript/zig/zig.exe`;
		put(source,
			"#include <process.h>\n#include <stdlib.h>\n#include <string.h>\n"
			+ windowsDriverQuoter()
			+ "int main(int argc, char **argv) {\n"
			+ "  if (getenv(\"MSC_BOUNDARY_REJECT_DISPATCH\")) {\n"
			+ "    int compile = 0;\n"
			+ "    for (int i = 1; i < argc; i++) if (strcmp(argv[i], \"-c\") == 0) compile = 1;\n"
			+ "    if (compile) for (int i = 1; i < argc; i++) if (strstr(argv[i], \"_dispatch.\")) return 98;\n"
			+ "  }\n"
			+ "  char **args = malloc(sizeof(char *) * (argc + 2));\n"
			+ `  args[0] = quoteArgument("${zig}");\n`
			+ "  args[1] = \"cc\";\n"
			+ "  for (int i = 1; i < argc; i++) args[i + 1] = quoteArgument(argv[i]);\n"
			+ "  args[argc + 1] = NULL;\n"
			+ `  return (int)_spawnv(_P_WAIT, "${zig}", (const char * const *)args);\n`
			+ "}\n");
		need(command(dir, "project-driver", "gcc", [source, "-o", wrapper]).code == 0, "compile project driver");
		return wrapper;
	}
	const wrapper = `${dir}/project-cc`;
	put(wrapper, "#!/bin/sh\n"
		+ "compile=\nfor a in \"$@\"; do [ \"$a\" = -c ] && compile=1; done\n"
		+ "if [ -n \"$compile\" ] && [ -n \"$MSC_BOUNDARY_REJECT_DISPATCH\" ]; then\n"
		+ "  for a in \"$@\"; do case \"$a\" in *_dispatch.*) exit 98 ;; esac; done\n"
		+ "fi\n"
		+ "exec clang \"$@\"\n");
	need(chmod(wrapper, 493).ok, "chmod project driver");
	return wrapper;
}

function runProjectCache(): void {
	const savedCache = env.get("MSC_CACHE_DIR");
	const savedReject = env.get("MSC_BOUNDARY_REJECT_DISPATCH");
	const savedDisabled = env.get("MSC_NO_GLOBAL_CACHE");
	const driver = projectDriver(root);
	env.delete("MSC_BOUNDARY_REJECT_DISPATCH");
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	for (const name of ["project outputs", "project outputs with spaces"]) {
		const dir = fixture(name, "@compile(\"./native.c\");",
			"#ifdef __OPTIMIZE__\nint probeValue(void) { return 163; }\n#else\nint probeValue(void) { return 157; }\n#endif\n");
		env.set("MSC_CACHE_DIR", `${dir}/local`);
		need(build(dir, "debug-a", "probe", [], driver) == 0, "project debug output");
		need(value(dir) == "157", "project debug value");
		need(build(dir, "debug-a-settled", "probe", [], driver) == 0, "project debug settled");
		need(build(dir, "release-b", "probe-b", ["--release"], driver) == 0, "project release output");
		need(value(dir, "probe-b") == "163", "project release value");
		env.set("MSC_BOUNDARY_REJECT_DISPATCH", "1");
		const returned = build(dir, "return-debug-a", "probe", [], driver);
		env.delete("MSC_BOUNDARY_REJECT_DISPATCH");
		recordTrue(`independent output and configuration skips dispatcher ${name}`, returned == 0);
		if (returned == 0) record(`independent output preserves debug behavior ${name}`, "157", value(dir));
		put(`${dir}/native.c`, "int probeValue(void) { return 167; }\n");
		need(build(dir, "debug-source-changed", "probe", [], driver) == 0, "project changed source debug");
		record(`retained debug record invalidates changed native source ${name}`, "167", value(dir));
		need(build(dir, "release-source-changed", "probe-b", ["--release"], driver) == 0, "project changed source release");
		record(`retained release record invalidates changed native source ${name}`, "167", value(dir, "probe-b"));
	}
	if (savedCache == "") env.delete("MSC_CACHE_DIR"); else env.set("MSC_CACHE_DIR", savedCache);
	if (savedReject == "") env.delete("MSC_BOUNDARY_REJECT_DISPATCH"); else env.set("MSC_BOUNDARY_REJECT_DISPATCH", savedReject);
	if (savedDisabled == "") env.delete("MSC_NO_GLOBAL_CACHE"); else env.set("MSC_NO_GLOBAL_CACHE", savedDisabled);
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

	const meta = `${root}/comptime-meta`;
	ensureDir(meta);
	put(`${meta}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${meta}/lib.ms`, "import { Node, NodeKind, readFile } from \"std/meta\";\n\nexport macro third(): Node {\n\treturn { kind: NodeKind.StringLiteral, line: 1, column: 1, value: readFile(\"third.txt\") };\n}\n");
	put(`${meta}/main.ms`, "import { readFile } from \"std/meta\";\nimport { third } from \"./lib\";\n\nconst FIRST: string = @comptime { return readFile(\"first.txt\"); };\n\nconsole.log(FIRST + third());\n");
	put(`${meta}/first.txt`, "a");
	put(`${meta}/third.txt`, "b");
	need(build(meta, "meta-baseline") == 0, "std/meta baseline");
	need(build(meta, "meta-unchanged") == 0, "std/meta unchanged rebuild");
	need(value(meta) == "ab", "std/meta baseline value");
	put(`${meta}/first.txt`, "c");
	record("std/meta readFile edit read by a compile-time block", "cb", builtValue(meta, build(meta, "meta-block-change")));
	put(`${meta}/third.txt`, "d");
	record("std/meta readFile edit read by a macro declared in another module", "cd", builtValue(meta, build(meta, "meta-macro-change")));

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

function runObjectStore(): void {
	const first = includedFixture("store first", "static inline int probeValue(void) { return 55; }\n");
	const second = includedFixture("store second", "static inline int probeValue(void) { return 55; }\n");
	waitForNextSecond();
	need(build(first, "first") == 0, "store first build");
	need(build(second, "second", "probe", ["--verbose"]) == 0, "store second build");
	record("a fresh directory compiles only its own module", "1", recompiledObjects(second, "second"));
	record("a fresh directory build output", "55", value(second));

	const edited = fixture("store header", "@compile(\"./native.c\");", "#include \"value.h\"\nint probeValue(void) { return VALUE; }\n", "#define VALUE 11\n");
	waitForNextSecond();
	need(build(edited, "baseline") == 0, "store header baseline");
	need(value(edited) == "11", "store header baseline value");
	removeAll(`${edited}/out`);
	need(build(edited, "stored", "probe", ["--verbose"]) == 0, "store header reuse");
	record("a stored object rebuilds nothing in its own directory", "0", recompiledObjects(edited, "stored"));
	removeAll(`${edited}/out`);
	put(`${edited}/value.h`, "#define VALUE 22\n");
	record("a stored object after its header changed", "22", builtValue(edited, build(edited, "header-change")));

	const shadowed = `${root}/store shadow`;
	ensureDir(`${shadowed}/inc1`);
	ensureDir(`${shadowed}/inc2`);
	put(`${shadowed}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${shadowed}/api.h`, "int probeValue(void);\n");
	put(`${shadowed}/main.ms`, "@include(\"./api.h\");\n@compile(\"./native.c\");\nextern function probeValue(): int32;\nconsole.log(probeValue());\n");
	put(`${shadowed}/native.c`, "#include \"value.h\"\nint probeValue(void) { return VALUE; }\n");
	put(`${shadowed}/inc2/value.h`, "#define VALUE 11\n");
	const searched = ["--passC=-Iinc1 -Iinc2"];
	waitForNextSecond();
	need(build(shadowed, "baseline", "probe", searched) == 0, "store shadow baseline");
	need(value(shadowed) == "11", "store shadow baseline value");
	removeAll(`${shadowed}/out`);
	put(`${shadowed}/inc1/value.h`, "#define VALUE 33\n");
	record("a stored object after an earlier include dir gained its header", "33", builtValue(shadowed, build(shadowed, "shadow", "probe", searched)));

	const tool = fixture("store-toolchain", "@compile(\"./native.c\");", "int probeValue(void) { return TOOL_VALUE; }\n");
	const firstTool = writeWrapper(tool, 57);
	waitForNextSecond();
	need(build(tool, "first-toolchain", "probe", [], firstTool) == 0, "store first toolchain");
	need(value(tool) == "57", "store first toolchain value");
	removeAll(`${tool}/out`);
	const secondTool = writeWrapper(tool, 59);
	record("a stored object after the C compiler changed", "59", builtValue(tool, build(tool, "second-toolchain", "probe", [], secondTool)));
}

function pinnedRun(dir: string, exe: string): string {
	if (windows) {
		const script = `$p = Start-Process '${dir}/${exe}' -PassThru -NoNewWindow -RedirectStandardOutput '${dir}/pinned.out'; $p.ProcessorAffinity = 1; $null = $p.Handle; if (-not $p.WaitForExit(30000)) { $p.Kill(); 'TIMEOUT' } else { 'exit=' + $p.ExitCode }`;
		const r = execFileCapture("powershell", ["-NoProfile", "-Command", script]);
		const out = readFile(`${dir}/pinned.out`);
		return `${r.ok ? r.value.trim() : "powershell failed"} ${out.ok ? out.value.trim() : ""}`;
	}
	const r = execFileCapture("taskset", ["-c", "0", `${dir}/${exe}`]);
	return r.ok ? `exit=0 ${r.value.trim()}` : `exit=${r.error.exitCode} ${r.error.output.trim()}`;
}

function runSpawnDrain(): void {
	if (platform == "darwin") {
		console.log("skip spawn-drain: macOS has no CPU affinity to pin the run to one core");
		return;
	}
	const dir = `${root}/spawn-drain`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/main.ms`, "class A { name() { return \"A\"; } }\nclass B extends A { name() { return \"B\"; } }\nasync function main() {\n\tconsole.log(\"pre\");\n\tconst f = spawn(() => { return true ? new B() : new A(); });\n\tconst g: A = await f;\n\tconst x = spawn(() => 1);\n\tconst y = spawn(() => 2);\n\tconst s = (await x) + (await y);\n\tconst k = spawn(() => new B());\n\tconst h: A = await k;\n\tconsole.log(`post ${g.name()} ${s} ${h.name()}`);\n}\nmain();\n");
	need(build(dir, "spawn-drain", "probe.exe", ["--gc=drc"]) == 0, "spawn-drain build");
	let complete = 0;
	let firstBad = "none";
	for (let i = 0; i < 10; i++) {
		const run = pinnedRun(dir, "probe.exe");
		if (run.startsWith("exit=0") && run.contains("post B 3 B")) complete = complete + 1;
		else if (firstBad == "none") firstBad = `run ${i}: ${run}`;
	}
	record(`pinned to one CPU, the exit drain waits for every spawned task (first bad: ${firstBad})`, "10", `${complete}`);
}

function runDirectivePaths(): void {
	const dup = `${root}/dedupe-directive`;
	ensureDir(dup);
	put(`${dup}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dup}/api.h`, "int probeValue(void);\n");
	put(`${dup}/api.c`, "int probeValue(void) { return 53; }\n");
	put(`${dup}/main.ms`, "@compile(\"./api.c\");\nimport { probeValue } from \"./api.h\";\nconsole.log(probeValue());\n");
	need(build(dup, "dedupe") == 0, "dedupe directive build");
	record("explicit @compile dedupes with header companion", "53", value(dup));

	const nested = `${root}/dedupe-nested`;
	ensureDir(`${nested}/sub`);
	put(`${nested}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${nested}/sub/x.h`, "extern int xValue;\n");
	put(`${nested}/sub/x.c`, "int xValue = 59;\n");
	put(`${nested}/sub/lib.ms`, "export function readX(): number { return 0; }\n@compile(\"./x.c\");\n");
	put(`${nested}/main.ms`, "import { readX } from \"./sub/lib.ms\";\nimport { xValue } from \"./sub/x.h\";\nconsole.log(xValue);\n");
	need(build(nested, "dedupe-nested") == 0, "dedupe nested build");
	record("subdir module @compile dedupes with header companion", "59", value(nested));

	const abs = `${root}/link-absolute`;
	ensureDir(abs);
	put(`${abs}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${abs}/api.h`, "int probeValue(void);\n");
	put(`${abs}/native.c`, "int probeValue(void) { return 61; }\n");
	need(command(abs, "cc-abs", "clang", ["-c", "native.c", "-o", "native.o"]).code == 0, "cc abs");
	need(command(abs, "ar-abs", "ar", ["rcs", "libnative.a", "native.o"]).code == 0, "ar abs");
	put(`${abs}/main.ms`, "import { probeValue } from \"./api.h\";\n@link(\"" + abs + "/libnative.a\");\nconsole.log(probeValue());\n");
	need(build(abs, "link-absolute") == 0, "link absolute build");
	record("@link with absolute archive path", "61", value(abs));

	const bare = fixture("user-bare-compile", "@compile(\"native.c\");", "int probeValue(void) { return 71; }\n");
	need(build(bare, "user-bare-compile") == 0, "user bare @compile build");
	record("a user module's bare @compile path still resolves in its project", "71", value(bare));

	supportTreeOverDecoy("std @compile", "runtime/core/string.c", "console.log(\"ab\".includes(\"b\"));\n", "true");
	supportTreeOverDecoy("platform runtime list", "runtime/promise/drain.c", "console.log(\"ab\".includes(\"b\"));\n", "true");
	supportTreeOverDecoy("std @passC -I", "vendor/mbedtls/tf-psa-crypto/drivers/builtin/include/mbedtls/private/bignum.h", "console.log((12345678901234567890n * 3n).toString());\n", "37037036703703703670");
}

function supportTreeOverDecoy(site: string, decoy: string, program: string, expected: string): void {
	const dir = `${root}/decoy-${decoy.split("/").join("-")}`;
	const slash = decoy.lastIndexOf("/");
	ensureDir(`${dir}/${decoy.slice(0, slash)}`);
	put(`${dir}/${decoy}`, "#error the cwd checkout's support tree was compiled\n");
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/main.ms`, program);
	const code = build(dir, "decoy", "probe", ["--passC=-DMSC_SUPPORT_DECOY"]);
	record(`a ${site} path reads the support tree beside the compiler, not the cwd's ${decoy}`, expected, code == 0 ? value(dir) : `build exit ${code}`);
}

function runUpcastCast(): void {
	const dir = `${root}/upcast-cast`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/main.ms`, [
		"interface A { a: int32; }",
		"interface B extends A { b: int32; }",
		"interface C extends B { c: int32; }",
		"interface P { a: int32; }",
		"interface Q { a: int32; q: int32; }",
		"class Animal { legs: int32 = 4; legCount(): int32 { return this.legs; } }",
		"class Dog extends Animal { name: string = \"d\"; }",
		"function readA(x: A): int32 { return x.a; }",
		"function readMaybe(x: A | null): int32 { return x === null ? 0 : x.a; }",
		"function readP(p: P): int32 { return p.a; }",
		"function countLegs(x: Animal): int32 { return x.legs; }",
		"function deep(x: C): int32 { return readA(x); }",
		"function maybe(x: B): int32 { return readMaybe(x); }",
		"const c: C = { a: 1, b: 2, c: 3 };",
		"const q: Q = { a: 5, q: 6 };",
		"const dog = new Dog();",
		"console.log(`${deep(c)} ${maybe(c)} ${readP(q)} ${countLegs(dog)} ${dog.legCount()}`);",
		"",
	].join("\n"));
	need(build(dir, "upcast-cast", "probe", ["--passC=-Werror=incompatible-pointer-types"]) == 0, "upcast-cast build under -Werror=incompatible-pointer-types");
	record("a derived interface, a structural match and a class reach their base as a cast pointer", "1 1 5 4 4", value(dir));
}

function moduleNamesTree(parent: string): string {
	const app = `${parent}/app`;
	ensureDir(`${app}/sub`);
	ensureDir(`${parent}/shared`);
	put(`${app}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${app}/lib.ms`, "export class Point {\n\tx: number = 1;\n}\nexport function make(): Point { return new Point(); }\n");
	put(`${app}/sub/lib.ms`, "export class Point {\n\tx: number = 2;\n}\nexport function make(): Point { return new Point(); }\n");
	put(`${parent}/shared/lib.ms`, "export function shared(): string { return \"three\"; }\n");
	put(`${app}/main.ms`, [
		"import { make } from \"./lib\";",
		"import { make as makeSub } from \"./sub/lib\";",
		"import { shared } from \"../shared/lib\";",
		"console.log(`${make().x.toString()} ${makeSub().x.toString()} ${shared()}`);",
		"",
	].join("\n"));
	return app;
}

function builtText(path: string): string {
	const r = readFile(path);
	need(r.ok, `read ${path}`);
	return r.ok ? r.value : "";
}

function runModuleNames(): void {
	const short = moduleNamesTree(`${root}/a`);
	const long = moduleNamesTree(`${root}/a-much-longer-directory-name`);
	need(command(short, "js-short", compiler, ["build", "--target=js", "--output=out.js", "main.ms"]).code == 0, "module-names short js build");
	need(command(long, "js-long", compiler, ["build", "--target=js", "--output=out.js", "main.ms"]).code == 0, "module-names long js build");
	const shortJs = builtText(`${short}/out.js`);
	recordTrue("one program builds to the same JS bytes in directories of different lengths", shortJs == builtText(`${long}/out.js`));
	recordTrue("the JS bundle names no directory of the build machine", shortJs.indexOf("msc45native45boundary", 0) < 0 && shortJs.indexOf("msc-native-boundary", 0) < 0);
	const ran = command(short, "js-run", "node", ["out.js"]);
	record("same-basename modules and a module outside the project keep their own names on JS", "1 2 three", ran.code == 0 ? ran.stdout.trim() : `exit ${ran.code}`);
	need(build(long, "c-long") == 0, "module-names c build");
	recordTrue("the C binary's symbols name no directory of the build machine", builtText(`${long}/probe`).indexOf("msc45native45boundary", 0) < 0);
	record("same-basename modules and a module outside the project keep their own names on C", "1 2 three", value(long));
}

function toolPresent(exe: string): boolean {
	return execFileCapture(exe, ["--version"]).ok;
}

function runWasiPlatform(): void {
	if (!toolPresent("node")) {
		need(group != "wasi-platform", "wasi-platform requires node on PATH");
		console.log("skip wasi-platform: node is required on PATH");
		return;
	}
	const dir = `${root}/wasi-platform`;
	const fixtures = absolute("src/test/fixtures/wasiPlatform");
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	for (const name of [
		"minimal.ms",
		"console.ms",
		"hostCall.ms",
		"hostCall.h",
		"platform.ms",
		"platformProbe.h",
		"run.cjs",
	]) {
		need(copyFile(`${fixtures}/${name}`, `${dir}/${name}`).ok, `copy WASI fixture ${name}`);
	}
	for (const name of ["minimal", "console", "hostCall", "platform"]) {
		const built = command(dir, `build-${name}`, compiler, [
			"build",
			`${name}.ms`,
			"--os=wasm",
			`--output=${name}.wasm`,
		]);
		need(built.code == 0, `WASI ${name} build`);
	}
	const names = ["minimal", "console", "hostCall", "platform", "platform"];
	const modes = ["plain", "plain", "host", "platform", "clockFailure"];
	const expected = ["", "7", "host=7", "1\n1234", "1\nclock failure trapped"];
	for (let i = 0; i < names.length; i++) {
		const label = `run-${names[i]}-${modes[i]}`;
		const ran = command(dir, label, "node", ["run.cjs", `${names[i]}.wasm`, modes[i]]);
		record(`${label} exit`, "0", `${ran.code}`);
		record(label, expected[i], ran.stdout.trim());
	}
}

function runEmccArgvFs(): void {
	if (!toolPresent("emcc") || !toolPresent("node")) {
		console.log("skip emcc-argv-fs: emcc and node are both required on PATH");
		return;
	}
	const dir = `${root}/emcc-argv-fs`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/main.ms`, [
		"import { readFile, writeFile, mkdir, exists, readDir, remove } from \"std/fs\";",
		"import { argv } from \"std/process\";",
		"const parts: string[] = [`argc=${argv.length - 1}`];",
		"for (let i = 1; i < argv.length; i++) parts.push(argv[i]);",
		"writeFile(\"note.txt\", \"kept\");",
		"const back = readFile(\"note.txt\");",
		"parts.push(back.ok ? back.value : \"read failed\");",
		"mkdir(\"sub\");",
		"writeFile(\"sub/inner.txt\", \"x\");",
		"parts.push(readDir(\"sub\").join(\",\"));",
		"remove(\"sub/inner.txt\");",
		"parts.push(`${exists(\"sub/inner.txt\")} ${exists(\"note.txt\")}`);",
		"console.log(parts.join(\"|\"));",
		"",
	].join("\n"));
	const built = command(dir, "emcc-argv-fs", compiler, ["build", "main.ms", "--os=emcc", "--passL=-sNODERAWFS=1", "--output=probe.js"]);
	need(built.code == 0, "emcc-argv-fs build");
	const none = command(dir, "emcc-argv-fs-none", "node", ["probe.js"]);
	record("an emcc program reads no arguments and uses the file system", "argc=0|kept|inner.txt|false true", none.stdout.trim());
	const two = command(dir, "emcc-argv-fs-two", "node", ["probe.js", "one", "two words"]);
	record("an emcc program receives its arguments in order", "argc=2|one|two words|kept|inner.txt|false true", two.stdout.trim());
}

function runEmccJspi(): void {
	if (!toolPresent("emcc") || !toolPresent("node")) {
		console.log("skip emcc-jspi: emcc and node are both required on PATH");
		return;
	}
	const dir = `${root}/emcc-jspi`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/spawnOnly.ms`, [
		"function sq(n: int32): int32 { return n * n; }",
		"async function settled(): Promise<int32> {",
		"\treturn await new Promise<int32>((resolve) => resolve(await spawn(() => sq(7))));",
		"}",
		"console.log(`${await settled()}`);",
		"",
	].join("\n"));
	put(`${dir}/timer.ms`, [
		"function waitSync(n: int32): int32 {",
		"\treturn await new Promise<int32>((resolve) => setTimeout(() => resolve(n), 5));",
		"}",
		"let total = 0;",
		"for (let i = 1; i <= 6; i++) total += waitSync(i);",
		"console.log(`total=${total}`);",
		"",
	].join("\n"));
	const plain = command(dir, "emcc-jspi-spawn", compiler, ["build", "spawnOnly.ms", "--os=emcc", "--output=spawnOnly.js"]);
	need(plain.code == 0, "emcc-jspi spawn-only build");
	const plainJs = readFile(`${dir}/spawnOnly.js`);
	recordTrue("an emcc program with no timer links no stack suspension", plainJs.ok && plainJs.value.indexOf("Suspending") < 0 && plainJs.value.indexOf("asyncify") < 0);
	record("an emcc program with no timer awaits a promise and a spawn", "49", command(dir, "emcc-jspi-spawn-run", "node", ["spawnOnly.js"]).stdout.trim());
	const timed = command(dir, "emcc-jspi-timer", compiler, ["build", "timer.ms", "--os=emcc", "--output=timer.js"]);
	need(timed.code == 0, "emcc-jspi timer build");
	const timedJs = readFile(`${dir}/timer.js`);
	recordTrue("an emcc program with a timer links JSPI", timedJs.ok && timedJs.value.indexOf("WebAssembly.Suspending") >= 0 && timedJs.value.indexOf("asyncify_start_unwind") < 0);
	const jspiByDefault = execFileCapture("node", ["-e", "process.exit(typeof WebAssembly.Suspending == 'function' ? 0 : 1)"]).ok;
	const nodeArgs = jspiByDefault ? ["timer.js"] : ["--experimental-wasm-jspi", "timer.js"];
	record("an emcc program waits on a timer from sync code", "total=21", command(dir, "emcc-jspi-timer-run", "node", nodeArgs).stdout.trim());
	put(`${dir}/rawSleep.ms`, "extern function msSleepMs(ms: int32): void;\nmsSleepMs(5);\nconsole.log(\"slept\");\n");
	const raw = command(dir, "emcc-jspi-raw", compiler, ["build", "rawSleep.ms", "--os=emcc", "--output=rawSleep.js"]);
	need(raw.code == 0, "emcc-jspi raw sleep build");
	const rawJs = readFile(`${dir}/rawSleep.js`);
	recordTrue("an emcc program that sleeps through a runtime extern links JSPI", rawJs.ok && rawJs.value.indexOf("WebAssembly.Suspending") >= 0);
	const rawArgs = jspiByDefault ? ["rawSleep.js"] : ["--experimental-wasm-jspi", "rawSleep.js"];
	record("an emcc program sleeps through a runtime extern", "slept", command(dir, "emcc-jspi-raw-run", "node", rawArgs).stdout.trim());
}

function runEmccWatchProcess(): void {
	if (!toolPresent("emcc") || !toolPresent("node")) {
		console.log("skip emcc-watch-process: emcc and node are both required on PATH");
		return;
	}
	const dir = `${root}/emcc-watch-process`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/main.ms`, [
		"import { watch } from \"std/fs/watch\";",
		"import { exec, execFileCapture } from \"std/process\";",
		"const w = watch(\".\", false);",
		"const e = exec(\"echo hi\");",
		"const f = execFileCapture(\"echo\", [\"hi\"]);",
		"console.log([",
		"\tw.ok ? \"watch ok\" : w.error.message,",
		"\te.ok ? `exec ${e.value.trim()}` : e.error.message,",
		"\tf.ok ? `execFile ${f.value.trim()}` : f.error.message,",
		"].join(\"|\"));",
		"",
	].join("\n"));
	const built = command(dir, "emcc-watch-process", compiler, ["build", "main.ms", "--os=emcc", "--passL=-sNODERAWFS=1", "--output=probe.js"]);
	need(built.code == 0, "emcc-watch-process build");
	const browser = command(dir, "emcc-watch-process-run", "node", ["probe.js"]);
	record(
		"an emcc program links watch and process spawn and each reports it is unsupported",
		"file watching has no backend for this platform yet|spawn failed: ENOSYS: process spawning is not supported on this target|spawnSync echo ENOSYS: process spawning is not supported on this target",
		browser.stdout.trim(),
	);
	const native = command(dir, "emcc-watch-process-native", compiler, ["build", "main.ms", "--output=native"]);
	need(native.code == 0, "emcc-watch-process native build");
	const ran = command(dir, "emcc-watch-process-native-run", `${dir}/native`, []);
	record("the same program on the host watches and spawns", "watch ok|exec hi|execFile hi", ran.stdout.trim());
}

function sdkPath(sdk: string): string {
	const r = execFileCapture("xcrun", ["--sdk", sdk, "--show-sdk-path"]);
	return r.ok ? r.value.trim() : "";
}

function bootedSimulator(): string {
	const r = execFileCapture("xcrun", ["simctl", "list", "devices", "booted"]);
	if (!r.ok) return "";
	for (const line of r.value.split("\n")) {
		const state = line.indexOf(" (Booted)");
		if (state < 0) continue;
		const open = line.lastIndexOf("(", state - 1);
		if (open >= 0) return line.slice(open + 1, state - 1);
	}
	return "";
}

function iosBuild(dir: string, label: string, target: string, sdk: string, output: string): number {
	const clang = execFileCapture("xcrun", ["--find", "clang"]);
	if (!clang.ok) {
		need(false, "xcrun --find clang");
		return -1;
	}
	const flags = `-target ${target} -isysroot ${sdk}`;
	return command(dir, label, compiler, ["build", "main.ms", "--os=ios", "--cpu=arm64", `--cc=${clang.value.trim()}`, `--passC=${flags}`, `--passL=${flags} ${dir}/host.c`, `--output=${output}`]).code;
}

const IOS_PROCESS_EXPECTED = "echo hi|path echo hi|cwd ok|path cwd ok|missing program not started 2|missing cwd not started 2|missing program without cwd not started 2|spawn cwd ok 0|spawnSync /bin/echo ENOENT|exec hi|true true";

function runIosProcess(): void {
	const device = platform == "darwin" ? sdkPath("iphoneos") : "";
	const simulator = platform == "darwin" ? sdkPath("iphonesimulator") : "";
	if (device == "" || simulator == "") {
		console.log("skip ios-process: xcrun with the iphoneos and iphonesimulator SDKs is required");
		return;
	}
	const dir = `${root}/ios-process`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/host.c`, "void MsMain(void);\nvoid msDrainUntilIdle(void);\nint main(void) { MsMain(); msDrainUntilIdle(); return 0; }\n");
	put(`${dir}/main.ms`, [
		"import { argv, cwd, env, exec, execFileResult, spawn, ChildStream, ExecFileResult } from \"std/process\";",
		"const here = argv[argv.length - 1];",
		"env.set(\"PATH\", \"/usr/bin:/bin\");",
		"function ran(label: string, r: ExecFileResult): string {",
		"\treturn r.started ? `${label} ${r.output.trim()}` : `${label} not started ${r.startErrno}`;",
		"}",
		"function inHere(label: string, r: ExecFileResult): string {",
		"\treturn r.started && r.output.trim().endsWith(\"/ios-process\") ? `${label} ok` : ran(label, r);",
		"}",
		"const child = spawn(\"/bin/pwd\", [\"-P\"], { cwd: here });",
		"let childText = \"\";",
		"if (child.ok) {",
		"\tconst out = child.value.read(ChildStream.Stdout, 5000);",
		"\tconst done = child.value.wait(5000);",
		"\tchildText = `spawn cwd ${out.ok && out.value.data.trim().endsWith(\"/ios-process\") ? \"ok\" : \"elsewhere\"} ${done.ok ? done.value.code : -1}`;",
		"} else childText = child.error.message;",
		"const childMissing = spawn(\"/bin/echo\", [\"hi\"], { cwd: `${here}/no-such-dir` });",
		"const shell = exec(\"echo hi\");",
		"console.log([",
		"\tran(\"echo\", execFileResult(\"/bin/echo\", [\"hi\"])),",
		"\tran(\"path echo\", execFileResult(\"echo\", [\"hi\"])),",
		"\tinHere(\"cwd\", execFileResult(\"/bin/pwd\", [\"-P\"], here)),",
		"\tinHere(\"path cwd\", execFileResult(\"pwd\", [\"-P\"], here)),",
		"\tran(\"missing program\", execFileResult(\"/no/such/program\", [], here)),",
		"\tran(\"missing cwd\", execFileResult(\"/bin/echo\", [\"hi\"], `${here}/no-such-dir`)),",
		"\tran(\"missing program without cwd\", execFileResult(\"/no/such/program\", [])),",
		"\tchildText,",
		"\tchildMissing.ok ? \"spawn missing cwd started\" : childMissing.error.message,",
		"\tshell.ok ? `exec ${shell.value.trim()}` : shell.error.message,",
		"\t`${cwd() != \"\"} ${env.get(\"HOME\") != \"\"}`,",
		"].join(\"|\"));",
		"",
	].join("\n"));
	record("an iOS device program that spawns, with and without a cwd, builds", "0", `${iosBuild(dir, "ios-device", "arm64-apple-ios15.0", device, "device")}`);
	record("the same program builds for the iOS simulator", "0", `${iosBuild(dir, "ios-simulator", "arm64-apple-ios15.0-simulator", simulator, "simulator")}`);
	const booted = bootedSimulator();
	if (booted == "") {
		console.log("skip ios-process simulator run: no booted simulator (xcrun simctl boot <device>)");
	} else {
		const ran = command(dir, "ios-simulator-run", "xcrun", ["simctl", "spawn", booted, `${dir}/simulator`, dir]);
		record("on the iOS simulator a spawn runs in its cwd and a missing program or cwd reports its errno", IOS_PROCESS_EXPECTED, ran.stdout.trim());
	}
	need(command(dir, "ios-process-native", compiler, ["build", "main.ms", "--cc=clang", "--output=native"]).code == 0, "ios-process native build");
	record("the same program on macOS through posix_spawn", IOS_PROCESS_EXPECTED, command(dir, "ios-process-native-run", `${dir}/native`, [dir]).stdout.trim());
	need(command(dir, "ios-process-fork", compiler, ["build", "main.ms", "--cc=clang", "--passC=-DMS_TEST_SPAWN_FORK", "--output=fork"]).code == 0, "ios-process fork-shim build");
	record("the same program on macOS through the fork shim iOS uses for a cwd", IOS_PROCESS_EXPECTED, command(dir, "ios-process-fork-run", `${dir}/fork`, [dir]).stdout.trim());
}

if (group == "argv" || group == "all") runArgv();
if (group == "compile-cache" || group == "all") runCompileCache();
if (group == "link-cache" || group == "all") runLinkCache();
if (group == "audit" || group == "all") runAudit();
if (group == "comptime-cache" || group == "all") runComptimeCache();
if (group == "object-store" || group == "all") runObjectStore();
if (group == "project-cache" || group == "all") runProjectCache();
if (group == "directive-paths" || group == "all") runDirectivePaths();
if (group == "spawn-drain" || group == "all") runSpawnDrain();
if (group == "upcast-cast" || group == "all") runUpcastCast();
if (group == "emcc-argv-fs" || group == "all") runEmccArgvFs();
if (group == "emcc-watch-process" || group == "all") runEmccWatchProcess();
if (group == "emcc-jspi" || group == "all") runEmccJspi();
if (group == "module-names" || group == "all") runModuleNames();
if (group == "wasi-platform" || group == "all") runWasiPlatform();
if (group == "ios-process" || group == "all") runIosProcess();

let failures = 0;
console.log(`root ${root}`);
for (const r of results) {
	const pass = r.expected == r.actual;
	if (!pass) failures = failures + 1;
	console.log(`${pass ? "pass" : "FAIL"}  ${r.name}  expected=${r.expected} actual=${r.actual}`);
}
if (failures == 0) removeAll(root);
exit(failures == 0 ? 0 : 1);
