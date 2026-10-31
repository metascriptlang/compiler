// @stdout: tcp send after the peer closed: -1
// @stdout: tcp sendAsync after the peer closed: -1
// @stdout: unix send after the peer closed: -1
// @stdout: unix sendAsync after the peer closed: -1
// @stdout: still running
// @skip-js: std/net and the io engine are C backend only
// @skip-raiser: std/net is a .cms module and the Raiser VM has no io engine
// @serial

import { accept, bind, bindUnix, close, connect, connectUnix, createSocket, createUnixSocket, listen, send, sendAsync, setNonBlocking } from "std/net";
import { argv } from "std/process";
import { basename, remove } from "std/fs";

function tcpPair(): int32[] {
	let port = (30000 + Date.now() % 20000) as int32;
	while (true) {
		const server = createSocket();
		if (bind(server, "127.0.0.1", port) >= 0 && listen(server, 4) >= 0) {
			const client = createSocket();
			connect(client, "127.0.0.1", port);
			const peer = accept(server);
			close(server);
			return [client, peer];
		}
		close(server);
		port = port + 1;
	}
}

function unixPair(path: string): int32[] {
	const server = createUnixSocket();
	bindUnix(server, path);
	listen(server, 4);
	const client = createUnixSocket();
	connectUnix(client, path);
	const peer = accept(server);
	close(server);
	remove(path);
	return [client, peer];
}

async function afterPeerClosed(kind: string, pair: int32[]): Promise<void> {
	close(pair[1]);
	let sync = send(pair[0], "x");
	while (sync > 0) sync = send(pair[0], "x");
	console.log(`${kind} send after the peer closed: ${sync}`);
	setNonBlocking(pair[0]);
	console.log(`${kind} sendAsync after the peer closed: ${await sendAsync(pair[0], "y")}`);
	close(pair[0]);
}

await afterPeerClosed("tcp", tcpPair());
await afterPeerClosed("unix", unixPair(`/tmp/msSigpipe-${basename(argv[0])}-${Date.now()}.sock`));
console.log("still running");
