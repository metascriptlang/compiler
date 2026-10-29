// @stdout: recv in a host loop: hello
// @stdout: send in a host loop: 5
// @stdout: host loop finished: 1
// @stdout: peer read: world
// @exit: 0
// @skip-js: binds the C fixture pump.c, a host loop that sleeps on the dispatcher selector fd
// @skip-raiser: binds the C fixture pump.c, which has no Raiser host bridge
// @serial
// note: a native host loop (a desktop window's run loop) sleeps in poll() on the dispatcher
//   selector fd and calls msRunOnce(0) when it turns readable; it never awaits. Before the fix
//   engine I/O never made that fd readable, so the loop slept through the recv and the send
//   started here. The peer reads before it returns, so its completion cannot wake the loop.

@include("./pump.h")
@compile("./pump.c")
extern function msTestHostLoopDone(): void;
extern function msTestHostLoopRun(maxMs: int32): int32;

import { createSocket, bind, listen, accept, connect, send, recv, close, recvAsync, sendAsync } from "std/net";

const port = (30000 + Date.now() % 20000) as int32;
const listenFd = createSocket();
bind(listenFd, "127.0.0.1", port);
listen(listenFd, 4);
const server = spawn((): string => {
	const c = accept(listenFd);
	send(c, "hello");
	const got = recv(c, 16);
	close(c);
	return got;
});
const client = createSocket();
connect(client, "127.0.0.1", port);

async function exchange(fd: int32): Promise<void> {
	const got = await recvAsync(fd, 16);
	console.log(`recv in a host loop: ${got}`);
	const sent = await sendAsync(fd, "world");
	console.log(`send in a host loop: ${sent}`);
	msTestHostLoopDone();
}

const pending = exchange(client);
console.log(`host loop finished: ${msTestHostLoopRun(10000)}`);
await pending;
console.log(`peer read: ${await server}`);
close(client);
close(listenFd);
