// @stdout: worker uring recv: hello
// @stdout: worker engine recv: hello
// @exit: 0
// @serial
// @skip-js: the io engine and the io_uring event loop are C backend only
// @skip-raiser
// note: a pool worker that ran an io_uring receive and an io-engine receive frees its ring, its 4 MB receive buffers and its engine when the pool shuts down (old runtime: LeakSanitizer reports the calloc in __ensureRecvBufs and in msIoEngineCreate once the worker exits). Off Linux the io_uring half reads with a plain recv.

import { createSocket, bind, listen, accept, connect, send, recv, close, recvAsync, msIoRunOnce } from "std/net";

@include("runtime/net/socket.h");
@include("runtime/net/eventLoopUring.h");
extern function msHasUringEventLoop(): int32;
extern function msUringEvtInit(): int32;
extern function msUringSubmitRecv(fd: int32, s: string, len: int32): void;
extern function msUringWait(timeoutMs: int32): int32;
extern function msUringEventRes(idx: int32): int32;
extern function msUringRecvData(fd: int32, bytesRecv: int32): string;

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

// [listener, client, server side]; the client has already sent "hello".
function connectedPair(): int32[] {
	const port = freePort();
	const lfd = createSocket();
	bind(lfd, "127.0.0.1", port);
	listen(lfd, 4);
	const cfd = createSocket();
	connect(cfd, "127.0.0.1", port);
	const sfd = accept(lfd);
	send(cfd, "hello");
	return [lfd, cfd, sfd];
}

function closeAll(fds: int32[]): void {
	for (const fd of fds) close(fd);
}

function uringTask(): int32 {
	const fds = connectedPair();
	let got = "";
	if (msHasUringEventLoop() == 1 && msUringEvtInit() == 0) {
		msUringSubmitRecv(fds[2], "", 4096);
		while (got == "") {
			if (msUringWait(-1) > 0) got = msUringRecvData(fds[2], msUringEventRes(0));
		}
	} else {
		got = recv(fds[2], 4096);
	}
	closeAll(fds);
	console.log(`worker uring recv: ${got}`);
	return 0;
}

async function readOnce(fd: int32, out: string[]): Promise<void> {
	out.push(await recvAsync(fd, 4096));
}

function engineTask(): int32 {
	const fds = connectedPair();
	const out: string[] = [];
	readOnce(fds[2], out);
	const t0 = Date.now();
	while (out.length == 0 && Date.now() - t0 < 10000) msIoRunOnce(10);
	closeAll(fds);
	console.log(`worker engine recv: ${out.length > 0 ? out[0] : "timeout"}`);
	return 0;
}

function spin(n: int32): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) s = (s + i) % 1000;
	return s;
}

await spawn(() => spin(10));
const u = spawn(() => uringTask());
spin(5000000);
await u;
const e = spawn(() => engineTask());
spin(5000000);
await e;
