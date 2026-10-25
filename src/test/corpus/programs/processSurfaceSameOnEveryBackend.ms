// @stdout: exec ok hi
// @stdout: exec exit non-zero 3
// @stdout: exec signal signal-terminated 15
// @stdout: env set v1 child v1 deleted <> home set
// @stdout: execFileResult started true pipeOk true code 4 out [out] err [err]
// @stdout: execFileResult missing started false errno 2
// note: std/process answers with the same types and values on every backend. Before the fix JS returned a number from `exec`, answered "" from every `env.get`, ignored `env.set`, and had no `execFileResult`.
// note: Windows has no signals, so that platform prints the signal line without running a child.
import { exec, env, execFileResult, platform, ProcessError, ProcessErrorKind } from "std/process";

const IS_WIN = platform == "windows";

function shell(posix: string, powershell: string): string {
	return IS_WIN ? `powershell -NoProfile -Command "${powershell}"` : posix;
}

function kindName(e: ProcessError): string {
	if (e.kind == ProcessErrorKind.NonZeroExit) return "non-zero";
	if (e.kind == ProcessErrorKind.SignalTerminated) return "signal-terminated";
	return "other";
}

const hi = exec(shell("printf hi", "[Console]::Out.Write('hi')"));
console.log(hi.ok ? `exec ok ${hi.value}` : `exec err ${hi.error.message}`);

const failed = exec(shell("exit 3", "exit 3"));
console.log(failed.ok ? "exec exit ran" : `exec exit ${kindName(failed.error)} ${failed.error.exitCode}`);

if (IS_WIN) {
	console.log("exec signal signal-terminated 15");
} else {
	const killed = exec("kill -TERM $$");
	console.log(killed.ok ? "exec signal ran" : `exec signal ${kindName(killed.error)} ${killed.error.signal}`);
}

env.set("MS_CORPUS_PROCESS_SURFACE", "v1");
const set = env.get("MS_CORPUS_PROCESS_SURFACE");
const child = exec(shell("printf %s \"$MS_CORPUS_PROCESS_SURFACE\"", "[Console]::Out.Write($env:MS_CORPUS_PROCESS_SURFACE)"));
env.delete("MS_CORPUS_PROCESS_SURFACE");
const deleted = env.get("MS_CORPUS_PROCESS_SURFACE");
const home = env.get(IS_WIN ? "USERPROFILE" : "HOME").length > 0 ? "set" : "empty";
console.log(`env set ${set} child ${child.ok ? child.value : "err"} deleted <${deleted}> home ${home}`);

const writerPath = IS_WIN ? env.get("SystemRoot") + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" : "/bin/sh";
const writerArgs = IS_WIN
	? ["-NoProfile", "-Command", "[Console]::Out.Write('out');[Console]::Error.Write('err');exit 4"]
	: ["-c", "printf out; printf err >&2; exit 4"];
const ran = execFileResult(writerPath, writerArgs);
console.log(`execFileResult started ${ran.started} pipeOk ${ran.pipeOk} code ${ran.exitCode} out [${ran.output}] err [${ran.errorOutput}]`);

const missing = execFileResult("no-such-program-ms", []);
console.log(`execFileResult missing started ${missing.started} errno ${missing.startErrno}`);
