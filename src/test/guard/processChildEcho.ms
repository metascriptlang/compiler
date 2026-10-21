// A spawned child is duplex: frames written to its stdin over time come back on stdout, closing
// stdin delivers EOF, and the read after the last byte reports `ended`; the status is {0, 0}.
// Chunk boundaries are not part of the contract, so the frames are compared concatenated.
//
// GUARD-BALANCE ChildProcess
// RED on a compiler without `spawn` in std/process (build error: no export 'spawn').

import { spawn, ChildProcess, ChildStream, exit } from "std/process";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function readUntil(child: ChildProcess, want: string): string {
	let text = "";
	while (text.byteLength < want.byteLength) {
		const got = child.read(ChildStream.Stdout, 5000);
		if (!got.ok) {
			report(`read: ${got.error.message}`);
			return text;
		}
		if (got.value.ended) return text;
		text += got.value.data;
	}
	return text;
}

const started = spawn("/bin/cat", []);
if (!started.ok) {
	report(`spawn: ${started.error.message}`);
} else {
	const child = started.value;
	for (const frame of ["Content-Length: 2\r\n\r\n{}", "second frame\n", "third: é\n"]) {
		const sent = child.write(frame, 5000);
		if (!sent.ok) report(`write: ${sent.error.message}`);
		const back = readUntil(child, frame);
		if (back != frame) report(`echo '${back}', want '${frame}'`);
	}
	child.closeStdin();
	const last = child.read(ChildStream.Stdout, 5000);
	if (!last.ok) {
		report(`read at EOF: ${last.error.message}`);
	} else if (!last.value.ended || last.value.data != "") {
		report(`after closeStdin: '${last.value.data}' ended=${last.value.ended}`);
	}
	const status = child.wait(5000);
	if (!status.ok) {
		report(`wait: ${status.error.message}`);
	} else if (status.value.code != 0 || status.value.signal != 0) {
		report(`status {${status.value.code}, ${status.value.signal}}`);
	}
	child.close();
	child.close();
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
