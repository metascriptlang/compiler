// INVARIANT: ULTRALOCK A6 and V0 (outside its methods an actor reference is its pid).
// RED MEANS: messaging a module const of actors from another thread is refused again.
// GUARD-JS

import { exit } from "std/process";

actor Counter {
	n: int32 = 0;
	add(k: int32): void { this.n += k; }
	read(): int32 { return this.n; }
}

actor Early {
	poke(k: int32): int32 { counter.add(k); one.add(k); return k; }
}

const counter = new Counter();
const one: Readonly<Counter> = new Counter();
const shards: Readonly<Counter[]> = [new Counter(), new Counter()];

function buildPair(): Counter[] {
	const out: Counter[] = [];
	for (let i = 0; i < 2; i++) out.push(new Counter());
	return out;
}
const more: Readonly<Counter[]> = buildPair();

actor Relay {
	poke(k: int32): int32 {
		one.add(k);
		shards[1].add(k);
		more[0].add(k);
		return k;
	}
}

function apply(f: Sendable<(k: int32) => void>, k: int32): void { f(k); }

const task = spawn((): int32 => {
	counter.add(2);
	return 0;
});
await task;
apply((k: int32): void => { one.add(k); shards[0].add(k); more[1].add(k); }, 3);
const relay = new Relay();
await relay.poke(4);
const early = new Early();
await early.poke(5);
const got = `${await counter.read()} ${await one.read()} ${await shards[0].read()} ${await shards[1].read()} ${await more[0].read()} ${await more[1].read()}`;
if (got != "7 12 3 4 4 3") {
	console.log(`GUARD-FAIL ${got}`);
	exit(1);
}
console.log("GUARD-OK");
