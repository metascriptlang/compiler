// A child that writes 1 MB to stderr before its one stdout line cannot block the parent that
// reads only stdout: every read also drains stderr, so the child never stalls on a full pipe.
//
// RED when the pump stops servicing stderr: the child blocks after 64 KB of stderr and the
// stdout read times out. RED on a compiler without `spawn` in std/process.

import { spawn, ChildStream, exit } from "std/process";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

const started = spawn("/bin/sh", ["-c", "head -c 1048576 /dev/zero >&2; echo done"]);
if (!started.ok) {
	report(`spawn: ${started.error.message}`);
} else {
	const child = started.value;
	let text = "";
	let ended = false;
	while (!ended) {
		const got = child.read(ChildStream.Stdout, 5000);
		if (!got.ok) {
			report(`stdout read: ${got.error.message}`);
			break;
		}
		ended = got.value.ended;
		text += got.value.data;
	}
	if (text != "done\n") report(`stdout '${text}', want 'done'`);
	const status = child.wait(5000);
	if (!status.ok) report(`wait: ${status.error.message}`);
	const drained = child.takeStderr();
	if (drained.byteLength != 1048576) {
		report(`stderr drained ${drained.byteLength} bytes, want 1048576`);
	}
	child.close();
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
