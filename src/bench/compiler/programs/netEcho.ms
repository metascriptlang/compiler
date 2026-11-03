import { argv } from "std/process";
import { createSocket, bind, listen, connect, close, recvAsync, sendAsync, acceptAsync } from "std/net";

const MESSAGE = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

function listenFree(from: int32): int32[] {
	let port = from;
	while (true) {
		const fd = createSocket();
		if (bind(fd, "127.0.0.1", port) >= 0 && listen(fd, 128) >= 0) return [fd, port];
		close(fd);
		port = port + 1;
	}
}

async function echo(fd: int32): Promise<void> {
	while (true) {
		const got = await recvAsync(fd, 4096);
		if (got.length == 0) break;
		await sendAsync(fd, got);
	}
	close(fd);
}

async function serve(listenFd: int32, connections: int32): Promise<void> {
	const handlers: Promise<void>[] = [];
	for (let i: int32 = 0; i < connections; i++) handlers.push(echo(await acceptAsync(listenFd)));
	for (const h of handlers) await h;
}

async function client(port: int32, messages: int32): Promise<int64> {
	const fd = createSocket();
	if (connect(fd, "127.0.0.1", port) < 0) throw new Error("connect failed");
	let bytes: int64 = 0;
	for (let i: int32 = 0; i < messages; i++) {
		await sendAsync(fd, MESSAGE);
		let got = 0;
		while (got < MESSAGE.length) {
			const chunk = await recvAsync(fd, 4096);
			if (chunk.length == 0) throw new Error("echo closed early");
			got += chunk.length;
		}
		bytes += got;
	}
	close(fd);
	return bytes;
}

async function once(kind: string, n: int32): Promise<int64> {
	const bound = listenFree((30000 + Date.now() % 20000) as int32);
	let total: int64 = 0;
	if (kind == "oneConn") {
		const server = serve(bound[0], 1);
		total = await client(bound[1], n);
		await server;
	} else if (kind == "manyConns") {
		const server = serve(bound[0], n);
		for (let i: int32 = 0; i < n; i++) total += await client(bound[1], 1);
		await server;
	} else {
		close(bound[0]);
		throw new Error(`unknown case ${kind}`);
	}
	close(bound[0]);
	return total;
}

async function run(kind: string, n: int32, reps: int32): Promise<int64> {
	let total: int64 = 0;
	for (let r: int32 = 0; r < reps; r++) total += await once(kind, n);
	return total;
}

async function main(): Promise<void> {
	if (argv.length > 3) {
		const total = await run(argv[1], argv[2].parseInt() as int32, argv[3].parseInt() as int32);
		console.log(`${argv[1]} ${argv[2]} ${total}`);
		return;
	}
	let total: int64 = await run("oneConn", 10000, 1);
	total += await run("manyConns", 3000, 1);
	console.log(`netEcho ${total}`);
}

await main();
