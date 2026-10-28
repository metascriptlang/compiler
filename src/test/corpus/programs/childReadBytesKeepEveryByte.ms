// Parity program (C only) — ChildProcess.readBytes returns each chunk's bytes untouched: a
// character split across two reads stays split, ill-formed bytes and NUL survive, and the
// concatenation of the chunks is exactly what the child wrote.
//
// @stdout: bytes length=6 e2,82,ac,ff,0,7a
// @skip-js: ChildProcess exists on the C and Raiser tiers only
// @skip-raiser: readBytes returns Buffer, which the Raiser tier has no type for
// @exit: 0

import { spawn, ChildStream, platform } from "std/process";

const shell = platform == "windows" ? "sh" : "/bin/sh";

const started = spawn(shell, ["-c", "printf '\\342\\202'; sleep 0.3; printf '\\254\\377\\000z'"]);
if (!started.ok) {
	console.log("spawn failed");
} else {
	const child = started.value;
	const seen: string[] = [];
	for (let i = 0; i < 1000; i++) {
		const got = child.readBytes(ChildStream.Stdout, 5000);
		if (!got.ok) break;
		for (let k = 0; k < got.value.data.length; k++) seen.push(got.value.data[k].toString(16));
		if (got.value.ended) break;
	}
	child.close();
	console.log(`bytes length=${seen.length} ${seen.join(",")}`);
}
