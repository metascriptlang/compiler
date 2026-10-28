// Parity program — text captured from a child is valid text on every backend: an ill-formed
// UTF-8 sequence in stdout or stderr reads as one U+FFFD, in a success value, in a
// ProcessError and in an ExecFileResult. Before the change C handed back the raw bytes inside the
// string, so `.length` and `charCodeAt` saw them while JS had already decoded.
//
// @stdout: exec length=3 units=61,fffd,62
// @stdout: execFileCapture length=3 units=63,fffd,64
// @stdout: failed output=78,fffd error=65,fffd code=3
// @stdout: result output=78,fffd error=65,fffd code=3
// @exit: 0

import { exec, execFileCapture, execFileResult, platform } from "std/process";

const shell = platform == "windows" ? "sh" : "/bin/sh";

function units(text: string): string {
	const out: string[] = [];
	for (let i = 0; i < text.length; i++) out.push(text.charCodeAt(i).toString(16));
	return out.join(",");
}

const viaShell = exec(`${shell} -c "printf 'a\\377b'"`);
console.log(viaShell.ok ? `exec length=${viaShell.value.length} units=${units(viaShell.value)}` : "exec err");

const direct = execFileCapture(shell, ["-c", "printf 'c\\377d'"]);
console.log(direct.ok ? `execFileCapture length=${direct.value.length} units=${units(direct.value)}` : "execFileCapture err");

const failing = ["-c", "printf 'x\\377'; printf 'e\\377' >&2; exit 3"];
const failed = execFileCapture(shell, failing);
console.log(failed.ok ? "failed ok" : `failed output=${units(failed.error.output)} error=${units(failed.error.errorOutput)} code=${failed.error.exitCode}`);

const result = execFileResult(shell, failing);
console.log(`result output=${units(result.output)} error=${units(result.errorOutput)} code=${result.exitCode}`);
