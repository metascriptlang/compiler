// @stdout: before: other=42
// @stdout: before: reader 0 got=5
// @stdout: after: other=42
// @stdout: after: reader 0 got=5
// @stdout: two: other=42
// @stdout: two: reader 0 got=5
// @stdout: two: reader 1 got=5
// @exit: 0
// @serial
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @skip-raiser
// note: a wait on the main thread runs only the task it awaits, never a spawned reader that loops until bytes the main thread writes after the wait (old pool: the help-first wait ran a reader inline and the program hung)

@include("./io.h");

import { createSelector, selectorRegister, selectorPoll, eventFd, EVENT_READ } from "std/runtime/selector";

extern function corpusWaitPipeOpen(i: int32): int32;
extern function corpusWaitPipeReadFd(i: int32): int32;
extern function corpusWaitPipeWrite(i: int32, b: int32): int32;
extern function corpusWaitReadByte(fd: int32): int32;
extern function corpusWaitSleepMs(ms: int32): void;

const QUIT = 113;

function readUntilQuit(fd: int32): int32 {
	const sel = createSelector();
	selectorRegister(sel, fd, EVENT_READ);
	let got = 0;
	while (true) {
		const n = selectorPoll(sel, -1 as int32);
		if (n > 0 && eventFd(0) == fd) {
			const b = corpusWaitReadByte(fd);
			if (b == QUIT || b < 0) break;
			got = got + 1;
		}
	}
	return got;
}

function feed(pipes: int32): void {
	for (let b = 0; b < 5; b++) {
		for (let i = 0; i < pipes; i++) corpusWaitPipeWrite(i, 65 + b);
		corpusWaitSleepMs(5);
	}
	for (let i = 0; i < pipes; i++) corpusWaitPipeWrite(i, QUIT);
}

function readerBefore(): void {
	corpusWaitPipeOpen(0);
	const fd = corpusWaitPipeReadFd(0);
	const reader = spawn(() => readUntilQuit(fd));
	const other = spawn(() => 40 as int32 + 2 as int32);
	console.log(`before: other=${await other}`);
	feed(1);
	console.log(`before: reader 0 got=${await reader}`);
}

function readerAfter(): void {
	corpusWaitPipeOpen(0);
	const fd = corpusWaitPipeReadFd(0);
	const other = spawn(() => 40 as int32 + 2 as int32);
	const reader = spawn(() => readUntilQuit(fd));
	console.log(`after: other=${await other}`);
	feed(1);
	console.log(`after: reader 0 got=${await reader}`);
}

function twoReaders(): void {
	corpusWaitPipeOpen(0);
	corpusWaitPipeOpen(1);
	const fd0 = corpusWaitPipeReadFd(0);
	const fd1 = corpusWaitPipeReadFd(1);
	const reader0 = spawn(() => readUntilQuit(fd0));
	const reader1 = spawn(() => readUntilQuit(fd1));
	const other = spawn(() => 40 as int32 + 2 as int32);
	console.log(`two: other=${await other}`);
	feed(2);
	console.log(`two: reader 0 got=${await reader0}`);
	console.log(`two: reader 1 got=${await reader1}`);
}

readerBefore();
readerAfter();
twoReaders();
