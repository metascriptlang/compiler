// Shared path resolution utilities for the MetaScript compiler.

import { argv, cwd, env, execPath, platform } from "std/process";
import { exists, realpath, ensureDir, writeFile, remove, removeAll, symlink } from "std/fs";
import { dirname, join, isAbsolute, normalize } from "std/fs/path";

// ~/.metascript. HOME wins over USERPROFILE on every host, so a Git-bash session on
// Windows resolves the same root as a POSIX one; "" when neither is set.
export function metascriptHome(): string {
	let home = env.get("HOME");
	if (home == "") home = env.get("USERPROFILE");
	if (home == "") return "";
	return join(home, ".metascript");
}

function firstSet(names: string[], fallback: string): string {
	for (const name of names) {
		const value = env.get(name);
		if (value != "") return value;
	}
	return fallback;
}

function posixTmpDir(): string {
	return firstSet(["TMPDIR"], "/tmp");
}

function windowsTmpDir(): string {
	return firstSet(["TMP", "TEMP", "USERPROFILE"], "C:\\Temp");
}

// The OS temp directory in std/os's order, without std/os, whose header cannot be included on Windows.
export function tmpDir(): string {
	return platform == "windows" ? windowsTmpDir() : posixTmpDir();
}

// Find the project root by walking up looking for build.ms.
// If entryFile is given (a relative one against CWD), walks up from its directory first.
// Falls back to walking up from CWD. Returns CWD if build.ms not found anywhere.
// This is the Go/Rust convention: the manifest defines the project root.
export function findProjectRoot(entryFile: string = ""): string {
	// Strategy 1: walk up from entry file's directory
	if (entryFile != "") {
		let dir = dirname(normalize(isAbsolute(entryFile) ? entryFile : join(cwd(), entryFile)));
		let depth = 0;
		while (depth < 20) {
			if (exists(join(dir, "build.ms"))) return dir;
			const parent = dirname(dir);
			if (parent == dir) { depth = 20; }
			else { dir = parent; depth = depth + 1; }
		}
	}
	// Strategy 2: walk up from CWD
	const here = normalize(cwd());
	let dir = here;
	let depth = 0;
	while (depth < 20) {
		if (exists(join(dir, "build.ms"))) return dir;
		const parent = dirname(dir);
		if (parent == dir) return here;
		dir = parent;
		depth = depth + 1;
	}
	return here;
}

// Resolve bare argv[0] (e.g. "msc") to full path by searching $PATH.
// Cross-platform: accepts both "/" and "\" as separators; detects PATH list
// delimiter (";" on Windows, ":" on Unix) by inspection.
export function resolveArgv0(arg0: string): string {
	// Already a path (has any separator or drive-letter prefix) — pass through
	let i = 0;
	while (i < arg0.length) {
		const c = arg0.charAt(i);
		if (c == "/" || c == "\\") return arg0;
		i = i + 1;
	}
	if (arg0.length >= 2 && arg0.charAt(1) == ":") return arg0;  // "C:foo"
	const pathEnv = env.get("PATH");
	if (pathEnv == "") return arg0;
	// Detect delimiter: ";" if present in PATH (Windows), else ":" (Unix).
	let hasSemi = false;
	let pi = 0;
	while (pi < pathEnv.length) {
		if (pathEnv.charAt(pi) == ";") { hasSemi = true; break; }
		pi = pi + 1;
	}
	const delim = hasSemi ? ";" : ":";
	let start = 0;
	let idx = 0;
	while (idx <= pathEnv.length) {
		if (idx == pathEnv.length || pathEnv.charAt(idx) == delim) {
			if (idx > start) {
				const dir = pathEnv.slice(start, idx);
				const candidate = join(dir, arg0);
				if (exists(candidate)) return candidate;
				// On Windows, also try with ".exe" suffix for bare names
				if (hasSemi) {
					const candidateExe = candidate + ".exe";
					if (exists(candidateExe)) return candidateExe;
				}
			}
			start = idx + 1;
		}
		idx = idx + 1;
	}
	return arg0;
}

// One spelling per directory. argv[0] decides how the compiler root is spelled,
// and the same root reached two ways used to produce two different strings:
// `<root>/./msc` left a trailing "." segment, `<root>\msc` left backslashes.
// That string is compared against module paths (compile.ms `isUnder`) to decide
// whether a module is user code; a mismatched spelling classified every stdlib
// path as user code and added -I<projectRoot> to it. The SAME runtime .c then
// compiled twice under two cache keys in one build and both objects reached the
// link line — `duplicate symbol: msPrintln` and ~100 more, with no hint that a
// path spelling was the cause.
function canonicalRootDir(dir: string): string {
	if (dir == "" || dir == ".") return cwd();
	const physical = realpath(dir);
	return normalize(physical != "" ? physical : dir);
}

let _hostRuntimeDir = "";

export function setHostRuntimeDir(root: string): void {
	_hostRuntimeDir = root == "" ? "" : canonicalRootDir(root);
}

// Find the compiler root directory (the one containing std/).
// Walks up from the running executable, then from argv[0] (resolved via $PATH if bare),
// then falls back to cwd(). A bare argv[0] looked up on PATH can name another install
// than the one running, which then compiles against that install's std.
export function resolveRuntimeDir(): string {
	if (_hostRuntimeDir != "") return _hostRuntimeDir;
	if (execPath != "") {
		const fromExe = runtimeDirFrom(execPath);
		if (fromExe != "") return fromExe;
	}
	const fromArgv0 = runtimeDirFrom(resolveArgv0(argv[0]));
	if (fromArgv0 != "") return fromArgv0;
	const base = cwd();
	if (exists(join(base, "std/core/system/index.ms"))) return base;
	return "";
}

// The directory of stand-in system headers cparse reads in place of the C compiler's own.
export function builtinIncludeDir(): string {
	const root = resolveRuntimeDir();
	return root != "" ? root + "/src/module/cparse/include" : "src/module/cparse/include";
}

// A builtin stub only stands in for a system header while cparse reads; the C compiler never sees it.
export function isBuiltinStubHeader(path: string): boolean {
	return path.startsWith(builtinIncludeDir() + "/") || path.startsWith("src/module/cparse/include/") || path.includes("/src/module/cparse/include/");
}

function runtimeDirFrom(exe: string): string {
	const physicalExe = realpath(exe);
	let base = dirname(physicalExe != "" ? physicalExe : exe);
	let i = 0;
	while (i < 4) {
		if (exists(join(base, "std/core/system/index.ms"))) {
			return canonicalRootDir(base);
		}
		base = dirname(base);
		i = i + 1;
	}
	return "";
}

test "runtimeDirFrom finds the install behind a symlinked binary or a symlinked bin directory" {
	if (platform == "windows") return;
	const probe = join(cwd(), "out/runtimeDirProbe");
	remove(join(probe, "path/msc"));
	remove(join(probe, "linkedBin"));
	removeAll(probe);
	const root = join(probe, "install");
	ensureDir(join(root, "std/core/system"));
	ensureDir(join(root, "bin"));
	ensureDir(join(probe, "path"));
	writeFile(join(root, "std/core/system/index.ms"), "");
	writeFile(join(root, "bin/msc"), "");
	assert symlink(join(root, "bin/msc"), join(probe, "path/msc")).ok;
	assert symlink(join(root, "bin"), join(probe, "linkedBin")).ok;
	const physicalRoot = realpath(root);
	assert runtimeDirFrom(join(probe, "path/msc")) == physicalRoot;
	assert runtimeDirFrom(join(probe, "linkedBin/msc")) == physicalRoot;
	assert runtimeDirFrom(join(root, "bin/msc")) == physicalRoot;
	remove(join(probe, "path/msc"));
	remove(join(probe, "linkedBin"));
	removeAll(probe);
}

test "execPath names the running binary as an absolute path, whatever argv[0] says" {
	assert execPath != "";
	assert isAbsolute(execPath);
	assert exists(execPath);
}

test "runtimeDirFrom answers only from the binary's own directories" {
	assert runtimeDirFrom(join(cwd(), "out/noSuchDir/a/b/c/d/e/msc")) == "";
}

test "canonicalRootDir — a trailing dot segment is dropped" {
	assert canonicalRootDir("C:/proj/compiler/.") == "C:/proj/compiler";
	assert canonicalRootDir("/proj/compiler/.") == "/proj/compiler";
}

test "canonicalRootDir — separators are unified" {
	assert canonicalRootDir("C:\\proj\\compiler") == "C:/proj/compiler";
}

test "canonicalRootDir — the two spellings of one root agree" {
	assert canonicalRootDir("C:/proj/compiler/.") == canonicalRootDir("C:\\proj\\compiler");
}

test "canonicalRootDir — a symlinked spelling resolves to the physical root" {
	if (platform == "darwin") assert canonicalRootDir("/tmp") == "/private/tmp";
	assert canonicalRootDir(".") == cwd();
}

test "findProjectRoot walks up from a relative entry's own directory" {
	const app = join(cwd(), "out/findRootProbe/app");
	removeAll(join(cwd(), "out/findRootProbe"));
	ensureDir(join(app, "src"));
	writeFile(join(app, "build.ms"), "export default {};\n");
	const direct = findProjectRoot("out/findRootProbe/app/main.ms").replaceAll("\\", "/");
	const nested = findProjectRoot("out/findRootProbe/app/src/main.ms").replaceAll("\\", "/");
	removeAll(join(cwd(), "out/findRootProbe"));
	assert direct.endsWith("out/findRootProbe/app");
	assert nested == direct;
}

test "findProjectRoot spells every root the way module paths are spelled" {
	assert !findProjectRoot("out/noRootProbe/main.ms").includes("\\");
	assert !findProjectRoot().includes("\\");
}

test "canonicalRootDir — an already-clean root is unchanged" {
	assert canonicalRootDir("C:/proj/compiler") == "C:/proj/compiler";
}

test "metascriptHome prefers HOME, falls back to USERPROFILE, and is empty without both" {
	const home = env.get("HOME");
	const profile = env.get("USERPROFILE");
	env.set("HOME", "/h");
	env.set("USERPROFILE", "/u");
	assert metascriptHome() == "/h/.metascript";
	env.set("HOME", "");
	assert metascriptHome() == "/u/.metascript";
	env.set("USERPROFILE", "");
	assert metascriptHome() == "";
	env.set("HOME", home);
	env.set("USERPROFILE", profile);
}

test "the POSIX temp directory is TMPDIR, then /tmp" {
	const saved = [env.get("TMPDIR"), env.get("TMP")];
	env.set("TMP", "/ignored");
	env.set("TMPDIR", "");
	assert posixTmpDir() == "/tmp";
	env.set("TMPDIR", "/a");
	assert posixTmpDir() == "/a";
	env.set("TMPDIR", saved[0]);
	env.set("TMP", saved[1]);
}

test "the Windows temp directory is TMP, then TEMP, then USERPROFILE, then the std fallback" {
	const saved = [env.get("TMP"), env.get("TEMP"), env.get("USERPROFILE"), env.get("TMPDIR")];
	env.set("TMPDIR", "/ignored");
	env.set("TMP", "");
	env.set("TEMP", "");
	env.set("USERPROFILE", "");
	assert windowsTmpDir() == "C:\\Temp";
	env.set("USERPROFILE", "/c");
	assert windowsTmpDir() == "/c";
	env.set("TEMP", "/b");
	assert windowsTmpDir() == "/b";
	env.set("TMP", "/a");
	assert windowsTmpDir() == "/a";
	env.set("TMP", saved[0]);
	env.set("TEMP", saved[1]);
	env.set("USERPROFILE", saved[2]);
	env.set("TMPDIR", saved[3]);
}

test "a builtin stub header is told from a user header by its directory, absolute or relative" {
	assert isBuiltinStubHeader(builtinIncludeDir() + "/stdint.h");
	assert isBuiltinStubHeader("src/module/cparse/include/stddef.h");
	assert !isBuiltinStubHeader("/proj/include/stdint.h");
}
