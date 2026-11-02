// @stdout: plain 1
// @stdout: if-return 2
// @stdout: loop-fresh 3
// @stdout: loop-rebind 2
// @stdout: loop-break 1
// @stdout: spawn-if-return 6
// @stdout: spawn-loop-rebind 16
// @stdout: top-level 2
// @stdout: actor-ref 5
// @exit: 0
// note: a `move` that no later path uses stays accepted: the join keeps a move only on a path that reaches the use, a loop may move a binding it rebinds before the next iteration, and a move followed by `break` or `return` ends the path

interface Counter { n: int32; }
class T { n: int32 = 0; }
actor Io {
	bump(t: T): int32 { t.n = t.n + 1; return t.n; }
}

async function plain(io: Io): Promise<number> {
	const t = new T();
	return await io.bump(move t);
}

async function ifReturn(io: Io, flag: boolean): Promise<number> {
	const t = new T();
	if (flag) {
		const r = await io.bump(move t);
		return r + 1;
	}
	return t.n;
}

async function loopFresh(io: Io): Promise<number> {
	let sum = 0;
	for (let i = 0; i < 3; i = i + 1) {
		const t = new T();
		sum = sum + await io.bump(move t);
	}
	return sum;
}

async function loopRebind(io: Io): Promise<number> {
	let t = new T();
	let last = 0;
	for (let i = 0; i < 2; i = i + 1) {
		last = await io.bump(move t);
		t = new T();
	}
	return last + t.n + 1;
}

async function loopBreak(io: Io): Promise<number> {
	const t = new T();
	let r = 0;
	for (let i = 0; i < 3; i = i + 1) {
		r = await io.bump(move t);
		break;
	}
	return r;
}

async function spawnIfReturn(flag: boolean): Promise<number> {
	const c: Counter = { n: 5 };
	if (flag) {
		const h = spawn(() => { c.n = c.n + 1; return c.n; }, { move: [c] });
		return await h;
	}
	return c.n;
}

async function spawnLoopRebind(): Promise<number> {
	let c: Counter = { n: 7 };
	let total = 0;
	for (let i = 0; i < 2; i = i + 1) {
		const h = spawn(() => { c.n = c.n + 1; return c.n; }, { move: [c] });
		total = total + await h;
		c = { n: 7 };
	}
	return total;
}

actor Peer { n: int32 = 0; }
actor Hub {
	hold(p: Peer): int32 { return 1; }
	holdMaybe(p: Peer | null): int32 { return 1; }
}

const io = new Io();
console.log(`plain ${await plain(io)}`);
console.log(`if-return ${await ifReturn(io, true)}`);
console.log(`loop-fresh ${await loopFresh(io)}`);
console.log(`loop-rebind ${await loopRebind(io)}`);
console.log(`loop-break ${await loopBreak(io)}`);
console.log(`spawn-if-return ${await spawnIfReturn(true)}`);
console.log(`spawn-loop-rebind ${await spawnLoopRebind()}`);
let topLevel = 0;
for (let r = 0; r < 2; r = r + 1) {
	const fresh = new T();
	topLevel = topLevel + await io.bump(move fresh);
}
console.log(`top-level ${topLevel}`);
const hub = new Hub();
let actorRef = 0;
for (let r = 0; r < 2; r = r + 1) {
	const viaNew = new Peer();
	actorRef = actorRef + await hub.hold(move viaNew);
	const viaSpawn = await spawn(() => new Peer());
	actorRef = actorRef + await hub.hold(move viaSpawn);
}
const maybePeer: Peer | null = await spawn(() => new Peer());
actorRef = actorRef + await hub.holdMaybe(move maybePeer);
console.log(`actor-ref ${actorRef}`);
