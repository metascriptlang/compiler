// Shared path resolution utilities for the MetaScript compiler.

import { argv, fileExists } from "std/process";
import { dirname, join } from "std/fs/path";

// Find the compiler root directory (the one containing std/).
// Resolves relative to the msc binary (argv[0]):
// 1. ./std  — production layout (msc + std/ in same directory)
// 2. ../std — development layout (bin/msc, std/ is one level up)
export function resolveRuntimeDir(): string {
	const binDir = dirname(argv[0]);
	if (fileExists(join(binDir, "std/core/system/index.ms"))) return binDir;
	const up = dirname(binDir);
	if (fileExists(join(up, "std/core/system/index.ms"))) return up;
	return "";
}
