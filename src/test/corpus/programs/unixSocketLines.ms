// @skip-js: std/net is a .cms module, C backend only
// @skip-raiser: std/net is a .cms module, C backend only
// @stdout: bind: 0
// @stdout: listen: 0
// @stdout: connect: 0
// @stdout: server read: ping
// @stdout: client read: pong
// @stdout: async server read: hello
// @stdout: path after close: exists
// @stdout: path after remove: gone
// @stdout: bind on a path in use: -1
// @stdout: connect to a stale socket file: -1
// @stdout: bind under a missing directory: -1
// @stdout: listen after that bind: -1
// @stdout: bind on an empty path: -1
// @stdout: connect to an empty path: -1
// @stdout: bind on a 103-byte path: 0
// @stdout: bind on a 108-byte path: -1
// @stdout: bind on a path holding a NUL byte: -1
// @stdout: connect to a missing socket: -1

import { argv } from "std/process";
import { basename, exists, mkdir, remove, removeAll } from "std/fs";
import { accept, acceptAsync, bindUnix, close, connectUnix, createUnixSocket, listen, recv, send, setTimeout } from "std/net";

const dir = `/tmp/msUnixSock-${basename(argv[0])}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
mkdir(dir);
const path = dir + "/s.sock";

function readLine(fd: int32): string {
	setTimeout(fd, 5000);
	return recv(fd, 64).toString().trim();
}

function pathOf(length: int32): string {
	return dir + "/" + "x".repeat(length - dir.length - 1);
}

const server = createUnixSocket();
console.log(`bind: ${bindUnix(server, path)}`);
console.log(`listen: ${listen(server, 4)}`);

const client = createUnixSocket();
const connected = connectUnix(client, path);
console.log(`connect: ${connected}`);
if (connected == 0) {
	const peer = accept(server);
	send(client, "ping\n");
	console.log(`server read: ${readLine(peer)}`);
	send(peer, "pong\n");
	console.log(`client read: ${readLine(client)}`);
	close(peer);
}
close(client);

const second = createUnixSocket();
if (connectUnix(second, path) == 0) {
	send(second, "hello\n");
	const asyncPeer = await acceptAsync(server);
	console.log(`async server read: ${readLine(asyncPeer)}`);
	close(asyncPeer);
}
close(second);

const taken = createUnixSocket();
console.log(`bind on a path in use: ${bindUnix(taken, path)}`);
close(taken);

close(server);
console.log(`path after close: ${exists(path) ? "exists" : "gone"}`);
const stale = createUnixSocket();
console.log(`connect to a stale socket file: ${connectUnix(stale, path)}`);
close(stale);
remove(path);
console.log(`path after remove: ${exists(path) ? "exists" : "gone"}`);

const refused = createUnixSocket();
console.log(`bind under a missing directory: ${bindUnix(refused, dir + "/no/such/dir/s.sock")}`);
console.log(`listen after that bind: ${listen(refused, 4)}`);
console.log(`bind on an empty path: ${bindUnix(refused, "")}`);
console.log(`connect to an empty path: ${connectUnix(refused, "")}`);
console.log(`bind on a path holding a NUL byte: ${bindUnix(refused, dir + "/a\u0000b.sock")}`);
console.log(`bind on a 108-byte path: ${bindUnix(refused, pathOf(108))}`);
close(refused);

const longest = createUnixSocket();
console.log(`bind on a 103-byte path: ${bindUnix(longest, pathOf(103))}`);
close(longest);

const orphan = createUnixSocket();
console.log(`connect to a missing socket: ${connectUnix(orphan, path)}`);
close(orphan);
removeAll(dir);
