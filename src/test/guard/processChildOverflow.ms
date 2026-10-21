// A stream nobody reads stops at the 16 MB buffer instead of dropping bytes: the child blocks,
// wait times out, the next read of that stream returns OutputOverflow, and reading on then
// delivers every byte the child wrote before EOF and a clean exit.
//
// RED when the buffer drops bytes past its cap (the total falls short) or never reports the
// overflow. RED on a compiler without `spawn` in std/process.

import { spawn, ChildStream, ProcessErrorKind, exit } from "std/process";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

const TOTAL = 20000000;

const started = spawn("/bin/sh", ["-c", `head -c ${TOTAL} /dev/zero`]);
if (!started.ok) {
	report(`spawn: ${started.error.message}`);
} else {
	const child = started.value;
	const blocked = child.wait(3000);
	if (blocked.ok || blocked.error.kind != ProcessErrorKind.Timeout) {
		report("wait finished while stdout was full and unread");
	}
	const first = child.read(ChildStream.Stdout, 0);
	if (first.ok || first.error.kind != ProcessErrorKind.OutputOverflow) {
		report("full unread stdout did not report OutputOverflow");
	}
	let total = 0;
	let ended = false;
	while (!ended) {
		const got = child.read(ChildStream.Stdout, 10000);
		if (!got.ok) {
			report(`read after overflow: ${got.error.message}`);
			break;
		}
		ended = got.value.ended;
		total += got.value.data.byteLength as int32;
	}
	if (total != TOTAL) report(`read ${total} bytes, the child wrote ${TOTAL}`);
	const status = child.wait(5000);
	if (!status.ok || status.value.code != 0) report("child did not exit cleanly after the drain");
	child.close();
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
