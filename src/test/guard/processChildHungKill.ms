// A child that never answers: read and wait each return Timeout at their deadline and leave it
// running; kill() ends it with SIGKILL and reaps it, so the status is {0, 9} and the pid is gone
// from the process table (no zombie). A second kill returns the same status without a signal.
//
// RED when kill skips the reap: `ps` still lists the pid as a zombie.
// RED on a compiler without `spawn` in std/process.

import { spawn, ChildStream, ProcessErrorKind, execFileResult, exit } from "std/process";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function listed(pid: int32): string {
	return execFileResult("/bin/ps", ["-o", "stat=", "-p", `${pid}`]).output.trim();
}

for (let round = 0; round < 3; round++) {
	const started = spawn("/bin/sleep", ["1000"]);
	if (!started.ok) {
		report(`spawn: ${started.error.message}`);
		break;
	}
	const child = started.value;
	const t0 = performance.now();
	const got = child.read(ChildStream.Stdout, 200);
	const readMs = performance.now() - t0;
	if (got.ok || got.error.kind != ProcessErrorKind.Timeout) {
		report("read of a silent child did not time out");
	}
	if (readMs < 190.0) report(`read returned after ${readMs} ms, deadline 200`);
	const waited = child.wait(100);
	if (waited.ok || waited.error.kind != ProcessErrorKind.Timeout) {
		report("wait on a running child did not time out");
	}
	if (listed(child.pid) == "") report("Timeout ended the child");
	const killed = child.kill();
	if (!killed.ok) {
		report(`kill: ${killed.error.message}`);
	} else if (killed.value.code != 0 || killed.value.signal != 9) {
		report(`kill status {${killed.value.code}, ${killed.value.signal}}`);
	}
	const state = listed(child.pid);
	if (state != "") report(`pid ${child.pid} still listed after kill: '${state}'`);
	const again = child.kill();
	if (!again.ok || again.value.signal != 9) report("second kill lost the status");
	child.close();
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
