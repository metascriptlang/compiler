// @stdout: timer stopped both before the cap: true
// @xfail(c): the main-thread actor poll drains actors re-queued during its pass, so the timer waits for the cap (inbox 2026-10-31-c-and-js-two-actors-messaging-each-other-starve-a-due-timer)
// @xfail(danger): the main-thread actor poll drains actors re-queued during its pass, so the timer waits for the cap (inbox 2026-10-31-c-and-js-two-actors-messaging-each-other-starve-a-due-timer)
// @xfail(san): the main-thread actor poll drains actors re-queued during its pass, so the timer waits for the cap (inbox 2026-10-31-c-and-js-two-actors-messaging-each-other-starve-a-due-timer)
// @xfail(js): the mailbox pump is a microtask, so the timer waits for the cap (inbox 2026-10-31-c-and-js-two-actors-messaging-each-other-starve-a-due-timer)
// @xfail(esm): the mailbox pump is a microtask, so the timer waits for the cap (inbox 2026-10-31-c-and-js-two-actors-messaging-each-other-starve-a-due-timer)
// note: two actors that message each other leave a due timer its turn, because an actor run is a turn of the loop beside the timers, not a promise job that runs before them. The cap only bounds a lane that starves the timer; there the timer runs after the exchange ends and prints false.

const CAP: int32 = 5000000;

actor Pong {
	peer: Ping | null = null;
	stopped: boolean = false;
	capped: boolean = false;
	setPeer(p: Ping): int32 {
		this.peer = p;
		return 0;
	}
	halt(): boolean {
		this.stopped = true;
		return this.capped;
	}
	hit(n: int32): void {
		if (this.stopped) return;
		if (n >= CAP) {
			this.capped = true;
			return;
		}
		const p = this.peer;
		if (p != null) p.hit(n + 1);
	}
}

actor Ping {
	peer: Pong | null = null;
	stopped: boolean = false;
	capped: boolean = false;
	setPeer(q: Pong): int32 {
		this.peer = q;
		return 0;
	}
	halt(): boolean {
		this.stopped = true;
		return this.capped;
	}
	hit(n: int32): void {
		if (this.stopped) return;
		if (n >= CAP) {
			this.capped = true;
			return;
		}
		const q = this.peer;
		if (q != null) q.hit(n + 1);
	}
}

async function stopBoth(p: Ping, q: Pong): Promise<void> {
	const a = await p.halt();
	const b = await q.halt();
	console.log(`timer stopped both before the cap: ${!a && !b}`);
}

async function main(): Promise<void> {
	const p = new Ping();
	const q = new Pong();
	await p.setPeer(q);
	await q.setPeer(p);
	p.hit(0);
	setTimeout((): void => { stopBoth(p, q); }, 10);
}

main();
