// @skip-js: std/net is a .cms module, C backend only
// @skip-raiser: std/net is a .cms module, C backend only
// @stdout: server read: ping
// @stdout: client read: pong
// @stdout: async server read: hello
// @stdout: path after close: exists
// @stdout: path after remove: gone
// @stdout: bind on a path in use: -1
// @stdout: bind under a missing directory: -1
// @stdout: listen after that bind: -1
// @stdout: bind on a path longer than sun_path: -1
// @stdout: bind on a path holding a NUL byte: -1
// @stdout: connect to a missing socket: -1

import { argv } from "std/process";
import { basename, exists, mkdir, remove, removeAll } from "std/fs";
import { accept, acceptAsync, bindUnix, close, connectUnix, createUnixSocket, listen, recv, send } from "std/net";

const dir = "/tmp/msUnixSock-" + basename(argv[0]);
removeAll(dir);
mkdir(dir);
const path = dir + "/s.sock";

const server = createUnixSocket();
console.log(`bind: ${bindUnix(server, path)}`);
console.log(`listen: ${listen(server, 4)}`);

const client = createUnixSocket();
console.log(`connect: ${connectUnix(client, path)}`);
const peer = accept(server);
send(client, "ping\n");
console.log(`server read: ${recv(peer, 64).toString().trim()}`);
send(peer, "pong\n");
console.log(`client read: ${recv(client, 64).toString().trim()}`);
close(peer);
close(client);

const second = createUnixSocket();
connectUnix(second, path);
send(second, "hello\n");
const asyncPeer = await acceptAsync(server);
console.log(`async server read: ${recv(asyncPeer, 64).toString().trim()}`);
close(asyncPeer);
close(second);

const taken = createUnixSocket();
console.log(`bind on a path in use: ${bindUnix(taken, path)}`);
close(taken);

close(server);
console.log(`path after close: ${exists(path) ? "exists" : "gone"}`);
remove(path);
console.log(`path after remove: ${exists(path) ? "exists" : "gone"}`);

const missing = createUnixSocket();
console.log(`bind under a missing directory: ${bindUnix(missing, dir + "/no/such/dir/s.sock")}`);
console.log(`listen after that bind: ${listen(missing, 4)}`);
console.log(`bind on a path longer than sun_path: ${bindUnix(missing, dir + "/" + "x".repeat(200))}`);
console.log(`bind on a path holding a NUL byte: ${bindUnix(missing, dir + "/a\u0000b.sock")}`);
close(missing);

const orphan = createUnixSocket();
console.log(`connect to a missing socket: ${connectUnix(orphan, path)}`);
close(orphan);
removeAll(dir);
