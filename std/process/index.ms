// Re-export error types so callers do `import { exec, ProcessError } from "std/process"`.
export { ProcessError, ProcessErrorKind } from "./errors";
export { processError, spawnFailed, notFound, nonZeroExit, signalTerminated, pipeError, isNotFound, isNonZeroExit, isRetryable } from "./errors";

export { argv, exit, cwd, exec, execFile, env, platform, arch } from "./kernel";

when (js) {
	export { readFile, writeFile, fileExists, readDir } from "./kernel";
} else {
	import { isExecutable } from "../fs";
	import { env, platform } from "./kernel";
	export { execFileCapture, execFileResult, ExecFileResult } from "./kernel";

	// =============================================================================
	// Executable lookup (PATH search)
	// =============================================================================
	//
	// Portable "find executable on PATH" — matches shutil.which (Python),
	// exec.LookPath (Go), Bun.which, and npm's `which`. Manual walk (no shell
	// subprocess, no OS SearchPathW quirks) with POSIX access(X_OK) and
	// Windows extension fallback (.exe / .cmd / .bat — Bun's minimal list).
	//
	// Semantics:
	//   1. Input with a separator (`/` or `\`) → direct lookup; never probed via
	//      PATH. Windows adds extension fallback if the input lacks a known suffix.
	//      (Security: matches Go/Bun behaviour — avoids accidental PATH shadowing.)
	//   2. Bare name → walks PATH (split on `;` on Windows, `:` elsewhere).
	//      First match wins.
	//   3. Windows per-dir: if input already ends in .exe/.cmd/.bat, exact match;
	//      otherwise try each suffix.
	//   4. POSIX per-dir: exact name, gated by access(X_OK) so the result reflects
	//      "the current user can invoke this file" rather than "file exists".
	//   5. CWD is NOT searched on POSIX (matches Go/Python security-aware default).

	const WIN_EXE_EXTS: string[] = [".exe", ".cmd", ".bat"];

	function hasWinExeSuffix(cmd: string): boolean {
		if (cmd.length < 4) return false;
		const tail = cmd.slice(cmd.length - 4, cmd.length).toLowerCase();
		for (const ext of WIN_EXE_EXTS) {
			if (tail == ext) return true;
		}
		return false;
	}

	export function findOnPath(cmd: string): string {
		if (cmd == "") return "";
		const isWin = platform == "windows";

		// Input with separator → direct lookup only; never fall through to PATH.
		if (cmd.indexOf("/") >= 0 || cmd.indexOf("\\") >= 0) {
			if (isExecutable(cmd)) return cmd;
			if (isWin && !hasWinExeSuffix(cmd)) {
				for (const ext of WIN_EXE_EXTS) {
					const candidate = cmd + ext;
					if (isExecutable(candidate)) return candidate;
				}
			}
			return "";
		}

		// Bare name → walk PATH.
		const pathEnv = env.get("PATH");
		if (pathEnv == "") return "";
		const sep = isWin ? ";" : ":";
		const alreadyHasExt = isWin && hasWinExeSuffix(cmd);
		for (const dir of pathEnv.split(sep)) {
			if (dir == "") continue;
			if (isWin) {
				if (alreadyHasExt) {
					const candidate = dir + "/" + cmd;
					if (isExecutable(candidate)) return candidate;
				} else {
					for (const ext of WIN_EXE_EXTS) {
						const candidate = dir + "/" + cmd + ext;
						if (isExecutable(candidate)) return candidate;
					}
				}
			} else {
				const candidate = dir + "/" + cmd;
				if (isExecutable(candidate)) return candidate;
			}
		}
		return "";
	}

	export function cmdExists(cmd: string): boolean {
		return findOnPath(cmd) != "";
	}
}
