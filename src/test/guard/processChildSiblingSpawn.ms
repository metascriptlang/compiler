// A child's pipes never leak into a sibling spawned while it is open, so closeStdin still gives
// it EOF while the sibling runs. Checked one sibling at a time, then with four threads spawning
// and echoing at once.
//
// RED when the pipes are created without FD_CLOEXEC: the sibling holds the first child's stdin
// open and the read for EOF times out. RED on a compiler without `spawn` in std/process.

import { spawn as spawnChild, ChildProcess, ChildStream, exit } from "std/process";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function drainToEnd(child: ChildProcess): Result<string, string> {
	let text = "";
	for (let i = 0; i < 1000; i++) {
		const got = child.read(ChildStream.Stdout, 3000);
		if (!got.ok) return Result.err(got.error.message);
		if (got.value.ended) return Result.ok(text);
		text += got.value.data;
	}
	return Result.err("no EOF after 1000 chunks");
}

function echoBesideSibling(k: int32): int32 {
	const first = spawnChild("/bin/cat", []);
	if (!first.ok) return 1;
	const sibling = spawnChild("/bin/cat", []);
	if (!sibling.ok) return 2;
	const child = first.value;
	const sent = child.write(`frame ${k}`, 3000);
	if (!sent.ok) return 3;
	child.closeStdin();
	const text = drainToEnd(child);
	sibling.value.close();
	child.close();
	if (!text.ok) return 4;
	return text.value == `frame ${k}` ? 0 : 5;
}

async function main(): Promise<void> {
	for (let round = 0; round < 5; round++) {
		const code = echoBesideSibling(round);
		if (code != 0) report(`serial round ${round}: failure ${code}`);
	}
	const hs: Promise<int32>[] = [];
	for (let t = 0; t < 4; t++) {
		const k = t;
		hs.push(spawn(() => {
			for (let i = 0; i < 5; i++) {
				const code = echoBesideSibling(k * 100 + i);
				if (code != 0) return code;
			}
			return 0;
		}));
	}
	const codes = await Promise.all(hs);
	for (const code of codes) {
		if (code != 0) report(`threaded: failure ${code}`);
	}
}

await main();
if (failed > 0) exit(1);
console.log("GUARD-OK");
