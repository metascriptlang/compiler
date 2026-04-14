// Shared path resolution utilities for the MetaScript compiler.

import { argv, cwd, getEnv } from "std/process";
import { exists } from "std/fs";
import { dirname, join } from "std/fs/path";

// Find the project root by walking up looking for build.ms.
// If entryFile is given (absolute path), walks up from its directory first.
// Falls back to walking up from CWD. Returns CWD if build.ms not found anywhere.
// This is the Go/Rust convention: the manifest defines the project root.
export function findProjectRoot(entryFile: string = ""): string {
	// Strategy 1: walk up from entry file's directory
	if (entryFile !== "" && entryFile.charAt(0) === "/") {
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
// Same heuristic as the reference compiler's getApplHeuristic.
function resolveArgv0(arg0: string): string {
	let i = 0;
	while (i < arg0.length) {
		if (arg0.charAt(i) === "/") return arg0;
		i = i + 1;
	}
	const pathEnv = getEnv("PATH");
	if (pathEnv === "") return arg0;
	let start = 0;
	let idx = 0;
	while (idx <= pathEnv.length) {
		if (idx === pathEnv.length || pathEnv.charAt(idx) === ":") {
			if (idx > start) {
				const dir = pathEnv.slice(start, idx);
				const candidate = join(dir, arg0);
				if (exists(candidate)) return candidate;
			}
			start = idx + 1;
		}
		idx = idx + 1;
	}
	return arg0;
}

// Find the compiler root directory (the one containing std/).
// Walks up from argv[0] (resolved via $PATH if bare), then falls back to cwd().
export function resolveRuntimeDir(): string {
	let base = dirname(resolveArgv0(argv[0]));
	let i = 0;
	while (i < 4) {
		if (exists(join(base, "std/core/system/index.ms"))) {
			if (base === "." || base === "") return cwd();
			return base;
		}
		base = dirname(base);
		i = i + 1;
	}
	// Fallback: cwd (needed when argv[0] doesn't resolve, e.g. Bun)
	base = cwd();
	if (exists(join(base, "std/core/system/index.ms"))) return base;
	return "";
}
