// @stdout: then ran 1 times before the 3000 ms poll expired: true
// @exit: 0
// @skip-js: the io engine is C backend only
// @skip-raiser
// note: a serve thread parked in its io engine poll wakes when an actor call chain it awaits resolves, so the continuation runs on the loop's next pump and not when the poll times out (old io_uring backend ignored the wake pipe a serve thread registers: under std/http every `.then` after an awaited actor call waited out the poll tick, one callback per tick). Bounded by a 3000 ms poll against a 40 ms method, so only a poll that never woke fails. Off Linux the wake goes through a different port (a completion posts to the dispatcher port, not the engine port a parked loop waits on) and the bound is not asserted.

import { platform } from "std/process";
@include("runtime/io/engine.h");
extern function msIoRunOnce(timeoutMs: int32): int32;
extern function msIoEngineAddWakeFd_ms(fd: int32): void;
extern function msGetWakePipeFd(): int32;
extern function msIoAccept_ms(listenFd: int32): Promise<int32>;

actor Source {
	take(): number {
		const t0 = Date.now();
		while (Date.now() - t0 < 40) {}
		return 1;
	}
}

actor Gate {
	source: Source;
	constructor(source: Source) {
		this.source = source;
	}
	pass(): number {
		return await this.source.take();
	}
}

async function wrapped(gate: Gate): Promise<number> {
	return await gate.pass();
}

import { createSocket, bind, listen, close } from "std/net";
const lfd = createSocket();
bind(lfd, "127.0.0.1", 0);
listen(lfd, 4);
const pending = msIoAccept_ms(lfd);
const wakeFd = msGetWakePipeFd();
msIoEngineAddWakeFd_ms(wakeFd);
let ran: number = 0;
wrapped(new Gate(new Source())).then((v: number): void => { ran += v; });
const t0 = Date.now();
while (ran == 0 && Date.now() - t0 < 10000) msIoRunOnce(3000);
close(lfd);
console.log(`then ran ${ran} times before the 3000 ms poll expired: ${platform != "linux" || Date.now() - t0 < 2500}`);
