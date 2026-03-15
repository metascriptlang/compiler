// Shared path resolution utilities for the MetaScript compiler.

import { argv, fileExists, cwd } from "std/process";
import { dirname, join } from "std/fs/path";

// Find the compiler root directory (the one containing std/).
// Walks up from argv[0], then falls back to cwd().
// Returns absolute path to avoid relative path issues in C binary.
export function resolveRuntimeDir(): string {
	let base = dirname(argv[0]);
	let i = 0;
	while (i < 4) {
		if (fileExists(join(base, "std/core/system/index.ms"))) {
			// Resolve "." to absolute cwd to avoid relative path issues in C binary
			if (base === "." || base === "") return cwd();
			return base;
		}
		base = dirname(base);
		i = i + 1;
	}
	// Fallback: cwd (needed when argv[0] doesn't resolve, e.g. Bun)
	base = cwd();
	if (fileExists(join(base, "std/core/system/index.ms"))) return base;
	return "";
}
