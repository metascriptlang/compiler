// @stdout: reads: 4 completed
// @stdout: stolen: yes
// @exit: 0
// @serial
// @skip-js: the io engine is C backend only
// @skip-raiser
// note: an actor visit a pool worker stole registers its recvAsync on that worker's io engine, so the worker polls the engine between tasks and while parked (old runtime with the steal wake: one of four reads never completed, 20 of 20 runs timed out)

import { createSocket, bind, listen, accept, connect, send, close, recvAsync, msIoRunOnce } from "std/net";
@include("runtime/actor/actor.h");
extern function msActorStolenVisits(): int64;

actor Reader {
	read(fd: int32): string { return await recvAsync(fd, 4096); }
}
actor Burner {
	burn(rounds: int64): uint64 {
		let x: uint64 = 1;
		for (let i: int64 = 0; i < rounds; i++) { x = x ^ (x << 13); x = x ^ (x >> 7); x = x ^ (x << 17); }
		return x;
	}
}

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

const N = 4;
const port = freePort();
const lfd = createSocket();
bind(lfd, "127.0.0.1", port);
listen(lfd, 16);
const cfds: int32[] = [];
const sfds: int32[] = [];
for (let i = 0; i < N; i++) {
	const c = createSocket();
	connect(c, "127.0.0.1", port);
	cfds.push(c);
	sfds.push(accept(lfd));
}
const readers: Reader[] = [];
const burners: Burner[] = [];
for (let i = 0; i < N; i++) { readers.push(new Reader()); burners.push(new Burner()); }
const burns: Promise<uint64>[] = [];
for (let i = 0; i < N; i++) burns.push(burners[i].burn(80000000));
const reads: Promise<string>[] = [];
for (let i = 0; i < N; i++) reads.push(readers[i].read(sfds[i]));
for (let i = 0; i < N; i++) send(cfds[i], "hello" + i);
let done = 0;
for (let i = 0; i < N; i++) reads[i].then((v: string) => { done++; });
const start = Date.now();
while (done < N && Date.now() - start < 10000) msIoRunOnce(5);
console.log(`reads: ${done} completed`);
console.log(`stolen: ${msActorStolenVisits() > 0 ? "yes" : "no"}`);
