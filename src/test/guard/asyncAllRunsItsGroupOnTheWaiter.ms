// nim-guard: an async function awaiting Promise.all over spawns runs its own group's queued
// tasks while it waits (ULTRALOCK T3: the waiter runs the Promise.all inputs, the future an async
// function awaits, and transitively their group children), for two inputs, three inputs and one
// async call deeper.
//
// Proven red with msPoolTaskIn matching a queued task only on its future, group or slot group:
// the walk from the async function reaches the group's done future, which no queued task
// carries, so the waiter runs none of them (0 edge runs per shape) and each round crosses to a
// worker and back.
//
// RED MEANS the waiter's dependency walk lost the group behind a done future; trace
// msPoolRunEdge / msPoolTaskIn against ULTRALOCK T3.

@passC("-DMSPOOL_STATS");
@compile("./fixtures/poolEdgeRuns.c");

import { msTestPoolEdgeRuns } from "./fixtures/poolEdgeRuns.h";

const rounds = 2000;

function work(k: int32): int32 {
	return k + 1;
}

async function viaTwo(): Promise<int32> {
	let s = 0;
	for (let i = 0; i < rounds; i++) {
		const k = i;
		const both = await Promise.all([spawn(() => work(k)), spawn(() => work(k))]);
		s += both[0] + both[1];
	}
	return s;
}

async function viaThree(): Promise<int32> {
	let s = 0;
	for (let i = 0; i < rounds; i++) {
		const k = i;
		const three = await Promise.all([spawn(() => work(k)), spawn(() => work(k)), spawn(() => work(k))]);
		s += three[0] + three[1] + three[2];
	}
	return s;
}

async function inner(k: int32): Promise<int32> {
	const both = await Promise.all([spawn(() => work(k)), spawn(() => work(k))]);
	return both[0] + both[1];
}

async function viaNested(): Promise<int32> {
	let s = 0;
	for (let i = 0; i < rounds; i++) s += await inner(i);
	return s;
}

function expectRuns(shape: string, before: int32): void {
	const runs = msTestPoolEdgeRuns() - before;
	if (runs <= 0) throw new Error(`${shape}: the waiter ran ${runs} of its group's queued tasks`);
}

let before = msTestPoolEdgeRuns();
const two = await viaTwo();
expectRuns("two inputs", before);
before = msTestPoolEdgeRuns();
const three = await viaThree();
expectRuns("three inputs", before);
before = msTestPoolEdgeRuns();
const nested = await viaNested();
expectRuns("one async call deeper", before);
console.log(`two ${two} three ${three} nested ${nested}: the waiter ran its group's tasks`);
