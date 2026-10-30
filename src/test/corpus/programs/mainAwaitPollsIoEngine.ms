// @stdout: recv awaited at top level: hello
// @stdout: accept awaited at top level: connected true
// @stdout: nextChanges awaited at top level: ended false names true
// @exit: 0
// @skip-js: the io engine and std/fs/watch are C backend only
// @xfail(raiser): the Raiser VM has no io engine
// @serial
// note: main awaits engine I/O with nothing pumping msIoRunOnce, so only the main-thread wait can
//   poll the engine. Before the fix that wait never polled it and each await hung. The watched
//   file is rewritten by an interval until the batch arrives, because the platform watcher
//   delivers late and coalesced; the workdir derives from argv[0] so lane cells never share it.

import { argv } from "std/process";
import { writeFile, removeAll, ensureDir, basename, dirname } from "std/fs";
import { watch, nextChanges } from "std/fs/watch";
import { createSocket, bind, listen, accept, connect, send, close, recvAsync, acceptAsync } from "std/net";

function bindFree(fd: int32, from: int32): int32 {
	let port = from;
	while (bind(fd, "127.0.0.1", port) < 0) port = port + 1;
	return port;
}

const basePort = (30000 + Date.now() % 20000) as int32;

const recvListen = createSocket();
const recvPort = bindFree(recvListen, basePort);
listen(recvListen, 4);
const server = spawn((): int32 => { const c = accept(recvListen); send(c, "hello"); return c; });
const client = createSocket();
connect(client, "127.0.0.1", recvPort);
const got = (await recvAsync(client, 16)).asString();
console.log(`recv awaited at top level: ${got}`);
close(await server);
close(client);
close(recvListen);

const acceptListen = createSocket();
const acceptPort = bindFree(acceptListen, recvPort + (1 as int32));
listen(acceptListen, 4);
const dialer = spawn((): int32 => { const fd = createSocket(); connect(fd, "127.0.0.1", acceptPort); return fd; });
const accepted = await acceptAsync(acceptListen);
console.log(`accept awaited at top level: connected ${accepted >= 0}`);
close(await dialer);
close(accepted);
close(acceptListen);

const root = "/tmp/mscorpusMainAwaitIo-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(root);
ensureDir(root);
const opened = watch(root, false);
if (!opened.ok) throw new Error("cannot watch " + root);
let rewrites = 0;
const churn = setInterval(() => {
	rewrites += 1;
	writeFile(`${root}/churn.txt`, `${rewrites}`);
}, 20);
const changes = await nextChanges(opened.value);
clearInterval(churn);
const named = changes.paths.some((p: string): boolean => p.includes("churn.txt"));
console.log(`nextChanges awaited at top level: ended ${changes.ended} names ${named}`);
removeAll(root);
