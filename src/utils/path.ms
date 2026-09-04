// Shared path resolution utilities for the MetaScript compiler.

import { argv, cwd, env } from "std/process";
import { exists } from "std/fs";
import { dirname, join, isAbsolute, normalize } from "std/fs/path";

// Find the project root by walking up looking for build.ms.
// If entryFile is given (absolute path), walks up from its directory first.
// Falls back to walking up from CWD. Returns CWD if build.ms not found anywhere.
// This is the Go/Rust convention: the manifest defines the project root.
export function findProjectRoot(entryFile: string = ""): string {
	// Strategy 1: walk up from entry file's directory
	if (entryFile !== "" && isAbsolute(entryFile)) {
		let dir = dirname(entryFile);
		let depth = 0;
		while (depth < 20) {
			if (exists(join(dir, "build.ms"))) return dir;
			const parent = dirname(dir);
			if (parent === dir) { depth = 20; }
			else { dir = parent; depth = depth + 1; }
		}
	}
	// Strategy 2: walk up from CWD
	let dir = cwd();
	let depth = 0;
	while (depth < 20) {
		if (exists(join(dir, "build.ms"))) return dir;
		const parent = dirname(dir);
		if (parent === dir) return cwd();
		dir = parent;
		depth = depth + 1;
	}
	return cwd();
}

// Resolve bare argv[0] (e.g. "msc") to full path by searching $PATH.
// Cross-platform: accepts both "/" and "\" as separators; detects PATH list
// delimiter (";" on Windows, ":" on Unix) by inspection.
export function resolveArgv0(arg0: string): string {
	// Already a path (has any separator or drive-letter prefix) — pass through
	let i = 0;
	while (i < arg0.length) {
		const c = arg0.charAt(i);
		if (c === "/" || c === "\\") return arg0;
		i = i + 1;
	}
	if (arg0.length >= 2 && arg0.charAt(1) === ":") return arg0;  // "C:foo"
	const pathEnv = env.get("PATH");
	if (pathEnv === "") return arg0;
	// Detect delimiter: ";" if present in PATH (Windows), else ":" (Unix).
	let hasSemi = false;
	let pi = 0;
	while (pi < pathEnv.length) {
		if (pathEnv.charAt(pi) === ";") { hasSemi = true; break; }
		pi = pi + 1;
	}
	const delim = hasSemi ? ";" : ":";
	let start = 0;
	let idx = 0;
	while (idx <= pathEnv.length) {
		if (idx === pathEnv.length || pathEnv.charAt(idx) === delim) {
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
	if (dir === "" || dir === ".") return cwd();
	return normalize(dir);
}

// Find the compiler root directory (the one containing std/).
// Walks up from argv[0] (resolved via $PATH if bare), then falls back to cwd().
export function resolveRuntimeDir(): string {
	let base = dirname(resolveArgv0(argv[0]));
	let i = 0;
	while (i < 4) {
		if (exists(join(base, "std/core/system/index.ms"))) {
			return canonicalRootDir(base);
		}
		base = dirname(base);
		i = i + 1;
	}
	// Fallback: cwd (needed when argv[0] doesn't resolve)
	base = cwd();
	if (exists(join(base, "std/core/system/index.ms"))) return base;
	return "";
}

test "canonicalRootDir — a trailing dot segment is dropped" {
	assert canonicalRootDir("C:/proj/compiler/.") === "C:/proj/compiler";
	assert canonicalRootDir("/proj/compiler/.") === "/proj/compiler";
}

test "canonicalRootDir — separators are unified" {
	assert canonicalRootDir("C:\\proj\\compiler") === "C:/proj/compiler";
}

test "canonicalRootDir — the two spellings of one root agree" {
	assert canonicalRootDir("C:/proj/compiler/.") === canonicalRootDir("C:\\proj\\compiler");
}

test "canonicalRootDir — an already-clean root is unchanged" {
	assert canonicalRootDir("C:/proj/compiler") === "C:/proj/compiler";
}
