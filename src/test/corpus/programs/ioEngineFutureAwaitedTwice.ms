// @stdout: watch future awaited twice: same true nonEmpty true names true|nextChanges awaited twice: ended false/false names true/true|next batch after both: ended false names true|recv future awaited twice: same true text hello over loopback
// @exit: 0
// @skip-js: std/fs/watch and the io engine are C backend only
// @skip-raiser
// note: a future the io engine makes holds its string like any other plain Promise<string>: every
//   await reads the same text. The engine's string futures took the value on the first read, so a
//   second await of the same watch or recv future read "" (the end-of-stream marker), and a second
//   concurrent nextChanges reported the watcher ended. Workdir derives from argv[0] so concurrent
//   lane cells never share a directory; the file is rewritten until each wait completes because
//   the platform watcher delivers late and coalesced.

import { argv } from "std/process";
import { writeFile, removeAll, ensureDir, basename, dirname } from "std/fs";
import { watch, nextChanges, msIoRunOnce, FsWatch } from "std/fs/watch";
import { createSocket, bind, listen, accept, connect, send, close } from "std/net";

@include("runtime/io/engine.h");
extern function msIoRecv_ms(fd: int32, maxBytes: int32): Promise<string>;

const root = "/tmp/mscorpusEngineTwice-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(root);
ensureDir(root);

let rewrites = 0;

function pumpUntil(done: () => boolean, churnDir: string): void {
	const start = performance.now();
	while (!done() && performance.now() - start < 120000) {
		if (churnDir != "") {
			rewrites += 1;
			writeFile(`${churnDir}/churn.ms`, `export const n = ${rewrites};`);
		}
		msIoRunOnce(100);
	}
}

function open(dir: string): FsWatch {
	ensureDir(dir);
	const opened = watch(dir);
	if (!opened.ok) throw new Error("cannot watch " + dir);
	return opened.value;
}

const rawDir = `${root}/raw`;
const rawWatch = open(rawDir);
const rawSeen: string[] = [];
async function readArmed(w: FsWatch): Promise<void> {
	const v = await w.armed;
	rawSeen.push(v);
}
readArmed(rawWatch);
readArmed(rawWatch);
pumpUntil((): boolean => rawSeen.length == 2, rawDir);
const rawLine = `watch future awaited twice: same ${rawSeen[0] == rawSeen[1]} nonEmpty ${rawSeen[0].length > 0} names ${rawSeen[0].includes("churn.ms")}`;

const batchDir = `${root}/batch`;
const batchWatch = open(batchDir);
const batchEnded: boolean[] = [];
const batchNamed: boolean[] = [];
async function readChanges(w: FsWatch): Promise<void> {
	const c = await nextChanges(w);
	batchEnded.push(c.ended);
	batchNamed.push(c.paths.includes("churn.ms"));
}
readChanges(batchWatch);
readChanges(batchWatch);
pumpUntil((): boolean => batchEnded.length == 2, batchDir);
const twiceLine = `nextChanges awaited twice: ended ${batchEnded[0]}/${batchEnded[1]} names ${batchNamed[0]}/${batchNamed[1]}`;
readChanges(batchWatch);
pumpUntil((): boolean => batchEnded.length == 3, batchDir);
const laterLine = `next batch after both: ended ${batchEnded[2]} names ${batchNamed[2]}`;

const listener = createSocket();
let port = 41000;
while (bind(listener, "127.0.0.1", port) < 0) port += 1;
listen(listener, 4);
const client = createSocket();
connect(client, "127.0.0.1", port);
const served = accept(listener);
send(client, "hello over loopback");
const recvd = msIoRecv_ms(served, 64);
const recvSeen: string[] = [];
async function readRecv(): Promise<void> {
	const v = await recvd;
	recvSeen.push(v);
}
readRecv();
readRecv();
pumpUntil((): boolean => recvSeen.length == 2, "");
const recvLine = `recv future awaited twice: same ${recvSeen[0] == recvSeen[1]} text ${recvSeen[0]}`;

close(client);
close(served);
close(listener);
removeAll(root);
console.log(`${rawLine}|${twiceLine}|${laterLine}|${recvLine}`);
