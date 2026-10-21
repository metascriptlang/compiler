// One 1.1 MB write to a child that echoes it completes: while stdin is being written the pump also
// drains stdout, so the echo never fills its pipe and stops reading ours (the two-pipe deadlock).
// The echoed bytes equal the written bytes.
//
// RED when the write path does not drain stdout: the write times out near 128 KB.
// RED on a compiler without `spawn` in std/process.

import { spawn, ChildStream, exit } from "std/process";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

const block = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/";
let payload = "";
for (let i = 0; i < 16384; i++) payload += `${i} ${block}\n`;

const started = spawn("/bin/cat", []);
if (!started.ok) {
	report(`spawn: ${started.error.message}`);
} else {
	const child = started.value;
	const sent = child.write(payload, 20000);
	if (!sent.ok) report(`write: ${sent.error.message}`);
	child.closeStdin();
	let echoed = "";
	let ended = false;
	while (!ended) {
		const got = child.read(ChildStream.Stdout, 10000);
		if (!got.ok) {
			report(`read: ${got.error.message}`);
			break;
		}
		ended = got.value.ended;
		echoed += got.value.data;
	}
	if (echoed.byteLength != payload.byteLength) {
		report(`echoed ${echoed.byteLength} bytes, want ${payload.byteLength}`);
	}
	else if (echoed != payload) report("echoed bytes differ from the written bytes");
	child.close();
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
