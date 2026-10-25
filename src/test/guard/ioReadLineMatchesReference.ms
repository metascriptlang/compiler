// readLine splits stdin into lines the way the reference's readLine does: a line ends at LF,
// one CR before that LF is dropped, a NUL is data, and the bytes after the last LF form one more
// line, kept whole up to EOF. The guard runs itself as a child per case and feeds the bytes
// through a pipe. Lengths sit on both sides of each buffer edge the kernel uses (the
// stack chunk of 256 bytes on Windows and 512 elsewhere, the first two doubled heap reads,
// the old 4096-byte buffer) and of the reference's own (80, then 127 more).
//
// RED on the C msReadLine (one 4096-byte fgets): a 5000-byte line splits in two, `A\0B` reads
// as `A`, a CRLF on the 4096 edge gives an extra empty line, a final bare CR is dropped.

import { spawn, ChildStream, argv, exit } from "std/process";
import { readLine } from "std/io";

if (argv.length > 1 && argv[1] == "child") {
	for (let i = 0; i < 3; i++) console.log(readLine().byteLength());
	exit(0);
}

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function expected(data: string): string {
	let out = "";
	let start = 0;
	for (let line = 0; line < 3; line++) {
		let length = 0;
		if (start < data.byteLength()) {
			let end = start;
			while (end < data.byteLength() && data.byteAt(end) != 10) end += 1;
			length = end - start;
			if (end < data.byteLength()) {
				if (length > 0 && data.byteAt(end - 1) == 13) length -= 1;
				start = end + 1;
			} else {
				start = end;
			}
		}
		out += `${length}\n`;
	}
	return out;
}

function runChild(data: string): string {
	const started = spawn(argv[0], ["child"]);
	if (!started.ok) return `spawn: ${started.error.message}`;
	const child = started.value;
	const wrote = child.write(data, 5000);
	if (!wrote.ok) return `write: ${wrote.error.message}`;
	child.closeStdin();
	let text = "";
	while (true) {
		const got = child.read(ChildStream.Stdout, 5000);
		if (!got.ok) return `read: ${got.error.message}`;
		if (got.value.ended) break;
		text += got.value.data;
	}
	child.wait(5000);
	child.close();
	return text;
}

const tails = ["\n", "\r\n", "\0\n", "\r", "\0", "", "\r\r\n", "\n\r"];
const lengths: int32[] = [0, 1, 77, 78, 79, 204, 205, 206, 254, 255, 256, 510, 511, 512, 1533, 1534, 1535, 3581, 4094, 4095, 4096, 5000];
let cases = 0;
for (const n of lengths) {
	for (const tail of tails) {
		const data = "A".repeat(n) + tail + (tail.byteLength() > 0 && tail.byteAt(tail.byteLength() - 1) == 10 ? "NEXT\n" : "");
		const want = expected(data);
		const got = runChild(data);
		if (got != want) report(`n=${n} tail=${JSON.stringify(tail)}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
		cases += 1;
	}
}

if (cases != 176) report(`ran ${cases} cases, want 176`);
if (failed > 0) exit(1);
console.log("GUARD-OK");
