// @stdout: shell missing program as the host shell reports it
// note: a missing program run through the shell is NotFound with exit code 127 under sh, the code `execFileCapture` reports for the same program; cmd.exe has no such code and exits 1, which is reported as a non-zero exit. Before the fix the error carried exit code 0.
import { exec, platform, ProcessErrorKind } from "std/process";

const expected = platform == "windows"
	? "other 1 command exited with status 1: no-such-program-ms x"
	: "not-found 127 command not found: no-such-program-ms x";
const r = exec("no-such-program-ms x");
const actual = r.ok ? "ran" : `${r.error.kind == ProcessErrorKind.NotFound ? "not-found" : "other"} ${r.error.exitCode} ${r.error.message}`;
console.log(actual == expected ? "shell missing program as the host shell reports it" : `shell ${actual}`);
