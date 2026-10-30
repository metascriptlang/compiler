// @stdout: small sent=all
// @stdout: large sent=all received=all
// @exit: 0
// @skip-js: the io engine is C backend only
// @xfail(raiser): the Raiser VM has no io engine
// @serial

import { createSocket, bind, listen, accept, connect, recv, close, setNonBlocking, sendAsync } from "std/net";

function listenFree(from: int32): int32[] {
	let port = from;
	while (true) {
		const fd = createSocket();
		if (bind(fd, "127.0.0.1", port) >= 0 && listen(fd, 4) >= 0) return [fd, port];
		close(fd);
		port = port + 1;
	}
}

async function sendAll(bytes: int32): Promise<int32[]> {
	const pair = listenFree((30000 + Date.now() % 20000) as int32);
	const reader = spawn((): int32 => {
		const c = accept(pair[0]);
		let total = 0;
		while (true) {
			const chunk = recv(c, 65536);
			if (chunk.length == 0) break;
			total = total + chunk.length;
		}
		close(c);
		return total;
	});
	const fd = createSocket();
	connect(fd, "127.0.0.1", pair[1]);
	setNonBlocking(fd);
	const sent = await sendAsync(fd, "x".repeat(bytes));
	close(fd);
	const received = await reader;
	close(pair[0]);
	return [sent, received];
}

const small = await sendAll(1000);
console.log(`small sent=${small[0] == 1000 ? "all" : small[0].toString()}`);

const large: int32 = 32000000;
const big = await sendAll(large);
console.log(`large sent=${big[0] == large ? "all" : big[0].toString()} received=${big[1] == large ? "all" : big[1].toString()}`);
