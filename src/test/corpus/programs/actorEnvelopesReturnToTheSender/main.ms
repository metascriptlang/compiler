// @maxrss: 16
// @stdout: 2000000 messages taken off the sender thread: true
// @skip-js: binds the C fixture offSender.c, which counts the thread each message runs on
// @skip-raiser: binds the C fixture offSender.c, which has no Raiser host bridge
// note: main sends every message and waits for each round in C, never in the event loop,
//   so it never runs B; B lives on the pool worker that ran the spawn, and every
//   envelope is allocated on main and freed on a worker. Before envelopes came from the
//   region heap, the worker kept each one in its own message pool and RSS grew to 127 MB.
@include("./offSender.h")
@compile("./offSender.c")
extern function probeMarkSender(): void;
extern function probeTake(): void;
extern function probeMade(): void;
extern function probeWaitMade(): int32;
extern function probeWaitTaken(n: int64): int32;
extern function probeOnSender(): int64;

actor B {
	take(v: int32): void {
		probeTake();
	}
}

const ROUND: int32 = 10000;
const ROUNDS: int32 = 200;
probeMarkSender();
const made = spawn((): B => {
	const b = new B();
	probeMade();
	return b;
});
let ok = probeWaitMade() == 1;
const b = await made;
for (let round: int32 = 1; ok && round <= ROUNDS; round++) {
	for (let i: int32 = 0; i < ROUND; i++) b.take(i);
	ok = probeWaitTaken((round as int64) * (ROUND as int64)) == 1;
}
console.log(`${(ROUNDS as int64) * (ROUND as int64)} messages taken off the sender thread: ${ok && probeOnSender() == 0}`);
