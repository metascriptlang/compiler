// @stdout: missing not-found 127 spawnSync no-such-program-ms ENOENT
// @stdout: directory spawn-failed 126 EACCES
// note: a program that cannot be started is an error that names it and its start error, as node's spawnSync does, with the shell's 127 (not found) or 126 (found, cannot start) as its exit code. Before the fix C reported a SpawnFailed error with exit code 0 and the message "fork/exec failed", and `execFileCapture` did not exist on JS.
import { cwd, execFileCapture, ProcessError, ProcessErrorKind } from "std/process";

function kindName(e: ProcessError): string {
	if (e.kind == ProcessErrorKind.NotFound) return "not-found";
	if (e.kind == ProcessErrorKind.SpawnFailed) return "spawn-failed";
	return "other";
}

const missing = execFileCapture("no-such-program-ms", ["x"]);
console.log(missing.ok ? "missing ran" : `missing ${kindName(missing.error)} ${missing.error.exitCode} ${missing.error.message}`);

const dir = cwd();
const directory = execFileCapture(dir, []);
const named = !directory.ok && directory.error.message == `spawnSync ${dir} EACCES`;
console.log(directory.ok ? "directory ran" : `directory ${kindName(directory.error)} ${directory.error.exitCode} ${named ? "EACCES" : directory.error.message}`);
