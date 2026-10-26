// Parity program — std/os tmpDir() on C. POSIX reads TMPDIR and falls back to /tmp when it is
// unset or empty; Windows asks the system for the temp directory, which ends in a backslash,
// and ignores TMPDIR.
// Axes: the inherited value, a value the program sets, the variable unset or empty.
//
// @skip-js: std/os has no JS surface
// @skip-raiser: the raiser tier of std/os has no tmpDir
// @stdout: inherited ok|set /corpusTmp/dir|unset /tmp|empty /tmp
// @exit: 0

import { tmpDir } from "std/os";
import { env, platform } from "std/process";

if (platform == "windows") {
	const dir = tmpDir();
	const ok = dir.length > 0 && dir.endsWith("\\");
	env.set("TMPDIR", "/corpusTmp/dir");
	const stillSystem = tmpDir() == dir;
	console.log(`inherited ${ok ? "ok" : "bad"}|set /corpusTmp/dir|unset /tmp|empty /tmp`);
	if (!stillSystem) console.log("windows tmpDir changed with TMPDIR");
} else {
	const inherited = env.get("TMPDIR");
	const seen = tmpDir() == (inherited != "" ? inherited : "/tmp") ? "ok" : "bad";
	env.set("TMPDIR", "/corpusTmp/dir");
	const set = tmpDir();
	env.delete("TMPDIR");
	const unset = tmpDir();
	env.set("TMPDIR", "");
	const empty = tmpDir();
	console.log(`inherited ${seen}|set ${set}|unset ${unset}|empty ${empty}`);
}
