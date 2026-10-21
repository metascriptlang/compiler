// Chunks are bytes: a child that writes each byte of `é` separately, with a pause between, can
// end a chunk inside the sequence, and the concatenation of the chunks equals the bytes written.
//
// RED on a compiler without `spawn` in std/process, or when a chunk is decoded or re-encoded
// on its own (the concatenation then differs).

import { spawn, ChildStream, exit } from "std/process";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

const script = "for i in 1 2 3; do printf '\\303'; sleep 0.05; printf '\\251'; sleep 0.05; done";
const started = spawn("/bin/sh", ["-c", script]);
if (!started.ok) {
	report(`spawn: ${started.error.message}`);
} else {
	const child = started.value;
	let text = "";
	let chunks = 0;
	let ended = false;
	while (!ended) {
		const got = child.read(ChildStream.Stdout, 5000);
		if (!got.ok) {
			report(`read: ${got.error.message}`);
			break;
		}
		ended = got.value.ended;
		if (!ended) chunks += 1;
		text += got.value.data;
	}
	if (text.byteLength != 6) report(`got ${text.byteLength} bytes, want 6`);
	if (text != "ééé") report("concatenated bytes are not 'ééé'");
	if (chunks < 2) report(`only ${chunks} chunk(s): the split case was not exercised`);
	child.close();
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
