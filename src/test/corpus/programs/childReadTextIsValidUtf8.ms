// Parity program (C and Raiser; the JS target has no ChildProcess) — a text read from a child
// pipe is valid text: an ill-formed sequence reads as U+FFFD, a character the pipe delivered
// in two pieces reads whole, and a sequence cut by the end of the stream reads as U+FFFD.
// Before the change a read returned the raw bytes, so a split character was two invalid strings.
//
// @stdout: split units=20ac,7a,fffd
// @stdout: cut at end units=71,fffd
// @skip-js: ChildProcess exists on the C and Raiser tiers only
// @exit: 0

import { spawn, ChildStream, platform } from "std/process";

const shell = platform == "windows" ? "sh" : "/bin/sh";

function units(text: string): string {
	const out: string[] = [];
	for (let i = 0; i < text.length; i++) out.push(text.charCodeAt(i).toString(16));
	return out.join(",");
}

function readAll(script: string): string {
	const started = spawn(shell, ["-c", script]);
	if (!started.ok) return "spawn failed";
	const child = started.value;
	let text = "";
	for (let i = 0; i < 1000; i++) {
		const got = child.read(ChildStream.Stdout, 5000);
		if (!got.ok) return "read failed";
		text += got.value.data;
		if (got.value.ended) break;
	}
	child.close();
	return text;
}

console.log(`split units=${units(readAll("printf '\\342\\202'; sleep 0.3; printf '\\254z\\377'"))}`);
console.log(`cut at end units=${units(readAll("printf 'q\\342\\202'"))}`);
