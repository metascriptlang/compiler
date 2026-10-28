// @stdout: once true
// @stdout: recv after a dropped watch: hello
// @stdout: recv after a dropped recv: world
// @exit: 0
// @skip-js: std/fs/watch and the io engine are C backend only
// @skip-raiser
// note: the io engine owns a reference to the future of each request it has in flight, so a future whose holder is gone (a FsWatch that left scope with its re-armed read pending, a recv started and dropped) is completed and freed by the engine and never written after it was freed (old runtime: the engine kept the raw pointer, the freed future's memory was reused by the next recv, and the late watch batch or late bytes overwrote its text: "recv: ca.ms"). Workdir derives from argv[0] like the other engine corpus programs.

import { argv } from "std/process";
import { writeFile, removeAll, ensureDir, basename, dirname } from "std/fs";
import { watch, nextChanges } from "std/fs/watch";
import { createSocket, bind, listen, accept, connect, send, close, recvAsync } from "std/net";

@include("runtime/io/engine.h");
extern function msIoRecv_ms(fd: int32, maxBytes: int32): Promise<string>;

const root = "/tmp/mscorpusDroppedFuture-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(root);
ensureDir(root);

async function once(dir: string): Promise<boolean> {
	const w = watch(dir);
	if (!w.ok) throw new Error("watch");
	writeFile(`${dir}/a.ms`, "1");
	const b = await nextChanges(w.value);
	return b.paths.length > 0;
}
console.log(`once ${await once(root)}`);
writeFile(`${root}/b.ms`, "2");

function freePort(): int32 {
	let port = (20000 + Date.now() % 20000) as int32;
	while (true) {
		const fd = createSocket();
		const ok = bind(fd, "127.0.0.1", port) >= 0;
		close(fd);
		if (ok) return port;
		port = port + 1;
	}
}

function pair(): int32[] {
	const lfd = createSocket();
	const port = freePort();
	bind(lfd, "127.0.0.1", port);
	listen(lfd, 4);
	const cfd = createSocket();
	connect(cfd, "127.0.0.1", port);
	const sfd = accept(lfd);
	close(lfd);
	return [cfd, sfd];
}

const first = pair();
send(first[0], "hello");
console.log(`recv after a dropped watch: ${await recvAsync(first[1], 64)}`);

function startAndDrop(fd: int32): void {
	msIoRecv_ms(fd, 64);
}
const a = pair();
startAndDrop(a[1]);
const b = pair();
send(a[0], "late");
send(b[0], "world");
console.log(`recv after a dropped recv: ${await recvAsync(b[1], 64)}`);
removeAll(root);
