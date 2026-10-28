// @xfail(raiser): std/net is a .cms module, C backend only
// @skip-js: std/net is a .cms module, C backend only
// @serial
// @stdout: full read seen=true total 20000
// note: a non-blocking recv that fills its whole 8192-byte buffer returns every byte without writing past it; the SAN cell is the contract.

import { createSocket, bind, listen, accept, connect, send, close, recvNonBlock, setNonBlocking } from "std/net";

function listenOnFreePort(): int32[] {
	let port = (20000 + Date.now() % 20000) as int32;
	while (true) {
		const fd = createSocket();
		if (bind(fd, "127.0.0.1", port) >= 0 && listen(fd, 1) >= 0) return [fd, port];
		close(fd);
		port = port + 1;
	}
}

const lp = listenOnFreePort();
const client = createSocket();
connect(client, "127.0.0.1", lp[1]);
const peer = accept(lp[0]);
send(client, "x".repeat(20000));
close(client);
setNonBlocking(peer);
let full = false;
let total = 0;
for (let i = 0; i < 100000 && total < 20000; i++) {
	const got = recvNonBlock(peer, 8192);
	if (got.length > 0) {
		if (got.length == 8192) full = true;
		total = total + got.length;
	}
}
console.log(`full read seen=${full} total ${total}`);
close(peer);
close(lp[0]);
