// @stdout: exec just-over 16777217 a-only
// @stdout: exec far-over 33554433 a-only
// @stdout: execFileCapture 17000000 a-only
// @stdout: execFileResult stderr 16777217 b-only code 0
// note: a captured stream keeps every byte the child wrote. Before the fix C and Raiser returned ok with the first 16777216 bytes and dropped the rest without a sign, on stdout and stderr alike.
import { env, exec, execFileCapture, execFileResult, platform } from "std/process";

const IS_WIN = platform == "windows";

function script(n: number, ch: string, toStderr: boolean): string {
	if (IS_WIN) return `[Console]::${toStderr ? "Error" : "Out"}.Write('${ch}'*${n})`;
	return `head -c ${n} /dev/zero | tr '\\0' '${ch}'${toStderr ? " >&2" : ""}`;
}

function shellLine(n: number, ch: string): string {
	return IS_WIN ? `powershell -NoProfile -Command "${script(n, ch, false)}"` : script(n, ch, false);
}

const writerPath = IS_WIN ? env.get("SystemRoot") + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" : "/bin/sh";

function writerArgs(n: number, ch: string, toStderr: boolean): string[] {
	return IS_WIN ? ["-NoProfile", "-Command", script(n, ch, toStderr)] : ["-c", script(n, ch, toStderr)];
}

function only(text: string, ch: string): string {
	return text.startsWith(ch) && text.endsWith(ch) ? `${ch}-only` : "mixed";
}

const justOver = exec(shellLine(16777217, "a"));
console.log(justOver.ok ? `exec just-over ${justOver.value.byteLength} ${only(justOver.value, "a")}` : `exec just-over err ${justOver.error.message}`);

const farOver = exec(shellLine(33554433, "a"));
console.log(farOver.ok ? `exec far-over ${farOver.value.byteLength} ${only(farOver.value, "a")}` : `exec far-over err ${farOver.error.message}`);

const capture = execFileCapture(writerPath, writerArgs(17000000, "a", false));
console.log(capture.ok ? `execFileCapture ${capture.value.byteLength} ${only(capture.value, "a")}` : `execFileCapture err ${capture.error.message}`);

const stderr = execFileResult(writerPath, writerArgs(16777217, "b", true));
console.log(`execFileResult stderr ${stderr.errorOutput.byteLength} ${only(stderr.errorOutput, "b")} code ${stderr.exitCode}`);
