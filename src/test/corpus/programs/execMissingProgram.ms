// @stdout: shell not-found 127 command not found: no-such-program-ms x
// note: a missing program run through the shell is NotFound with the shell's own exit code 127, the code `execFileCapture` reports for the same program. Before the fix the error carried exit code 0.
import { exec, ProcessErrorKind } from "std/process";

const r = exec("no-such-program-ms x");
console.log(r.ok ? "shell ran" : `shell ${r.error.kind == ProcessErrorKind.NotFound ? "not-found" : "other"} ${r.error.exitCode} ${r.error.message}`);
