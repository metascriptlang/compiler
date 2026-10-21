// A ChildProcess dropped without close() kills and reaps its child and closes its pipes: after the
// handle's scope ends the pid is gone from the process table and this process holds exactly the
// descriptors it held before. Covers a child still running and one that exited unreaped.
//
// GUARD-BALANCE ChildProcess
// RED when onDestroy skips the kill/reap (pid still listed) or a pipe leaks (fd count grows).
// RED on a compiler without `spawn` in std/process.

import { spawn, exit } from "std/process";
import { host, listed, onWindows } from "./fixtures/childHost";
import { readDir } from "std/fs";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function openFds(): int32 {
	return onWindows ? 0 : readDir("/dev/fd").length as int32;
}

function startAndDrop(program: string, args: string[]): int32 {
	const started = spawn(program, args);
	if (!started.ok) {
		report(`spawn ${program}: ${started.error.message}`);
		return 0;
	}
	return started.value.pid;
}

function exitedAndDropped(): int32 {
	const started = spawn(host("sh"), ["-c", "exit 0"]);
	if (!started.ok) {
		report(`spawn: ${started.error.message}`);
		return 0;
	}
	const child = started.value;
	for (let i = 0; i < 200 && !onWindows && !listed(`${child.pid}`).startsWith("Z"); i++) {}
	return child.pid;
}

const before = openFds();
for (let round = 0; round < 5; round++) {
	const running = startAndDrop(host("sleep"), ["1000"]);
	if (running != 0 && listed(`${running}`) != "") {
		report(`running child ${running} survived its handle: '${listed(`${running}`)}'`);
	}
	const zombie = exitedAndDropped();
	if (zombie != 0 && listed(`${zombie}`) != "") {
		report(`exited child ${zombie} left unreaped: '${listed(`${zombie}`)}'`);
	}
}
const after = openFds();
if (after != before) report(`open descriptors ${before} before, ${after} after`);

if (failed > 0) exit(1);
console.log("GUARD-OK");
