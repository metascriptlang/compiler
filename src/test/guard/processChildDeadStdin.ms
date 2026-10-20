// Writing to a child that no longer reads stdin returns PipeClosed and the parent keeps running:
// a write may never raise SIGPIPE in the parent. Two cases: the child has exited, and the child
// is alive with its stdin closed.
//
// RED when the SIGPIPE suppression is dropped: the guard dies with signal 13 at the first write.
// RED on a compiler without `spawn` in std/process.

import { spawn, ProcessErrorKind, exit } from "std/process";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

const exited = spawn("/bin/sh", ["-c", "exit 3"]);
if (!exited.ok) {
	report(`spawn: ${exited.error.message}`);
} else {
	const child = exited.value;
	const status = child.wait(5000);
	if (!status.ok || status.value.code != 3) report("exited child did not report status 3");
	const sent = child.write("nobody reads this\n", 1000);
	if (sent.ok || sent.error.kind != ProcessErrorKind.PipeClosed) {
		report("write to an exited child was not PipeClosed");
	}
	child.close();
}

const deaf = spawn("/bin/sh", ["-c", "exec 0<&-; exec sleep 1000"]);
if (!deaf.ok) {
	report(`spawn: ${deaf.error.message}`);
} else {
	const child = deaf.value;
	let closedSeen = false;
	for (let i = 0; i < 100 && !closedSeen; i++) {
		const sent = child.write("x", 100);
		if (!sent.ok && sent.error.kind == ProcessErrorKind.PipeClosed) {
			closedSeen = true;
		} else {
			const _paused = child.wait(50);
		}
	}
	if (!closedSeen) report("write to a child with stdin closed never returned PipeClosed");
	const killed = child.kill();
	if (!killed.ok || killed.value.signal != 9) report("kill after PipeClosed failed");
	child.close();
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
