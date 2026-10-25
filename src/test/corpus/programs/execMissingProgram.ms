// @stdout: shell missing program is the shell's non-zero exit
// note: `exec` runs its command through the host shell and reports what the shell returns, as node's execSync does: a missing program is a non-zero exit with the shell's code, 127 under sh and 1 under cmd.exe, never NotFound, because a program that exits 127 itself is indistinguishable from it. `execFileCapture` starts the program without a shell and reports NotFound on every host. Before the fix a shell exit of 127 was reported as NotFound on POSIX only.
import { exec, execFileCapture, platform, ProcessErrorKind } from "std/process";

const code = platform == "windows" ? 1 : 127;
const r = exec("no-such-program-ms x");
const shell = !r.ok && r.error.kind == ProcessErrorKind.NonZeroExit && r.error.exitCode == code && r.error.message == `command exited with status ${code}: no-such-program-ms x`;
const own = exec("exit 127");
const ownCode = !own.ok && own.error.kind == ProcessErrorKind.NonZeroExit && own.error.exitCode == 127;
const direct = execFileCapture("no-such-program-ms", ["x"]);
const found = !direct.ok && direct.error.kind == ProcessErrorKind.NotFound && direct.error.exitCode == 127;
console.log(shell && ownCode && found ? "shell missing program is the shell's non-zero exit" : `shell ${r.ok ? "ran" : `${r.error.kind} ${r.error.exitCode} ${r.error.message}`} own ${ownCode} direct ${found}`);
