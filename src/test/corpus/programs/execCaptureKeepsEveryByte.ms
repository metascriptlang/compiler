// @stdout: exec just-over 16777217 a-only
// @stdout: exec far-over 33554433 a-only
// @stdout: execFileCapture 17000000 a-only
// @stdout: execFileResult stderr 16777217 b-only code 0
// note: a captured stream keeps every byte the child wrote. Before the fix C and Raiser returned ok with the first 16777216 bytes and dropped the rest without a sign, on stdout and stderr alike.
import { exec, execFileCapture, execFileResult } from "std/process";

function writer(n: number, ch: string, redirect: string): string {
	return `head -c ${n} /dev/zero | tr '\\0' '${ch}'${redirect}`;
}

function only(text: string, ch: string): string {
	return text.startsWith(ch) && text.endsWith(ch) ? `${ch}-only` : "mixed";
}

const justOver = exec(writer(16777217, "a", ""));
console.log(justOver.ok ? `exec just-over ${justOver.value.byteLength} ${only(justOver.value, "a")}` : `exec just-over err ${justOver.error.message}`);

const farOver = exec(writer(33554433, "a", ""));
console.log(farOver.ok ? `exec far-over ${farOver.value.byteLength} ${only(farOver.value, "a")}` : `exec far-over err ${farOver.error.message}`);

const capture = execFileCapture("/bin/sh", ["-c", writer(17000000, "a", "")]);
console.log(capture.ok ? `execFileCapture ${capture.value.byteLength} ${only(capture.value, "a")}` : `execFileCapture err ${capture.error.message}`);

const stderr = execFileResult("/bin/sh", ["-c", writer(16777217, "b", " >&2")]);
console.log(`execFileResult stderr ${stderr.errorOutput.byteLength} ${only(stderr.errorOutput, "b")} code ${stderr.exitCode}`);
