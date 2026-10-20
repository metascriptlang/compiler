// @stdout: exec ok hi
// @stdout: exec exit non-zero 3
// @stdout: exec signal signal-terminated 15
// @stdout: env set v1 child v1 deleted <> home set
// @stdout: execFileResult started true pipeOk true code 4 out [out] err [err]
// @stdout: execFileResult missing started false errno 2
// note: std/process answers with the same types and values on every backend. Before the fix JS returned a number from `exec`, answered "" from every `env.get`, ignored `env.set`, and had no `execFileResult`.
import { exec, env, execFileResult, ProcessError, ProcessErrorKind } from "std/process";

function kindName(e: ProcessError): string {
	if (e.kind == ProcessErrorKind.NonZeroExit) return "non-zero";
	if (e.kind == ProcessErrorKind.SignalTerminated) return "signal-terminated";
	return "other";
}

const hi = exec("printf hi");
console.log(hi.ok ? `exec ok ${hi.value}` : `exec err ${hi.error.message}`);

const failed = exec("exit 3");
console.log(failed.ok ? "exec exit ran" : `exec exit ${kindName(failed.error)} ${failed.error.exitCode}`);

const killed = exec("kill -TERM $$");
console.log(killed.ok ? "exec signal ran" : `exec signal ${kindName(killed.error)} ${killed.error.signal}`);

env.set("MS_CORPUS_PROCESS_SURFACE", "v1");
const set = env.get("MS_CORPUS_PROCESS_SURFACE");
const child = exec("printf %s \"$MS_CORPUS_PROCESS_SURFACE\"");
env.delete("MS_CORPUS_PROCESS_SURFACE");
const deleted = env.get("MS_CORPUS_PROCESS_SURFACE");
const home = env.get("HOME").length > 0 ? "set" : "empty";
console.log(`env set ${set} child ${child.ok ? child.value : "err"} deleted <${deleted}> home ${home}`);

const ran = execFileResult("/bin/sh", ["-c", "printf out; printf err >&2; exit 4"]);
console.log(`execFileResult started ${ran.started} pipeOk ${ran.pipeOk} code ${ran.exitCode} out [${ran.output}] err [${ran.errorOutput}]`);

const missing = execFileResult("no-such-program-ms", []);
console.log(`execFileResult missing started ${missing.started} errno ${missing.startErrno}`);
