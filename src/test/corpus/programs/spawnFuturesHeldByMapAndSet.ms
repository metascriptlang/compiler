// @serial
// @stdout: local 5000
// @stdout: unawaited 2
// @stdout: strings s0s1s2
// @stdout: classes 9000
// @stdout: overwrite 7000
// @stdout: nested 6000
// @stdout: callee 3000
// @stdout: set 5000 2
// @stdout: module 17000 1
// note: a Map or Set entry holding a spawn future copied it without a count and destroyed
//   it with one, so the entry's destroy freed a future the completion queue still held
//   (ASan heap-use-after-free); an entry whose only managed field is the future had no
//   hooks the analyzer knew of, so a Set iteration released the last future twice.
//   Variants: local and module-level, awaited and not, int32, string and class payloads,
//   string and int32 keys, overwrite and delete, a Promise array as the value, a Map
//   filled by a callee, and a Set.

function work(k: int32): int32 {
	let n: int32 = 0;
	for (let i = 0; i < 1000; i++) n += k;
	return n;
}

function tag(k: int32): string { return `s${k}`; }

class Box {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

function box(k: int32): Box { return new Box(work(k)); }

async function localAwaited(): Promise<int32> {
	const byName = new Map<string, Promise<int32>>();
	byName.set("a", spawn(() => work(2)));
	byName.set("b", spawn(() => work(3)));
	let m: int32 = 0;
	for (const p of byName.values()) m += await p;
	return m;
}

function localUnawaited(): int32 {
	const byName = new Map<string, Promise<int32>>();
	byName.set("a", spawn(() => work(2)));
	byName.set("b", spawn(() => work(3)));
	return byName.size as int32;
}

async function strings(): Promise<string> {
	const byKey = new Map<int32, Promise<string>>();
	for (let w: int32 = 0; w < 3; w++) {
		const k = w;
		byKey.set(k, spawn(() => tag(k)));
	}
	let s = "";
	for (const p of byKey.values()) s += await p;
	return s;
}

async function classes(): Promise<int32> {
	const byKey = new Map<string, Promise<Box>>();
	byKey.set("x", spawn(() => box(4)));
	byKey.set("y", spawn(() => box(5)));
	let t: int32 = 0;
	for (const p of byKey.values()) t += (await p).v;
	return t;
}

async function overwrite(): Promise<int32> {
	const byName = new Map<string, Promise<int32>>();
	byName.set("a", spawn(() => work(2)));
	byName.set("a", spawn(() => work(7)));
	byName.set("b", spawn(() => work(1)));
	byName.delete("b");
	let m: int32 = 0;
	for (const p of byName.values()) m += await p;
	return m;
}

async function nested(): Promise<int32> {
	const groups = new Map<string, Promise<int32>[]>();
	groups.set("g", [spawn(() => work(1)), spawn(() => work(2))]);
	groups.set("h", [spawn(() => work(3))]);
	let m: int32 = 0;
	for (const ps of groups.values()) {
		for (const p of ps) m += await p;
	}
	return m;
}

function put(m: Map<int32, Promise<int32>>, k: int32): void {
	m.set(k, spawn(() => work(k)));
}

async function callee(): Promise<int32> {
	const byKey = new Map<int32, Promise<int32>>();
	put(byKey, 1);
	put(byKey, 2);
	let m: int32 = 0;
	for (const p of byKey.values()) m += await p;
	return m;
}

async function sets(): Promise<string> {
	const ps = new Set<Promise<int32>>();
	ps.add(spawn(() => work(2)));
	ps.add(spawn(() => work(3)));
	let m: int32 = 0;
	for (const p of ps) m += await p;
	const idle = new Set<Promise<int32>>();
	idle.add(spawn(() => work(1)));
	idle.add(spawn(() => work(1)));
	return `${m} ${idle.size}`;
}

const moduleMap = new Map<string, Promise<int32>>();
moduleMap.set("a", spawn(() => work(8)));
moduleMap.set("b", spawn(() => work(9)));
let moduleSum: int32 = 0;
for (const p of moduleMap.values()) moduleSum += await p;

const moduleIdle = new Map<string, Promise<int32>>();
moduleIdle.set("z", spawn(() => work(1)));

console.log(`local ${await localAwaited()}`);
console.log(`unawaited ${localUnawaited()}`);
console.log(`strings ${await strings()}`);
console.log(`classes ${await classes()}`);
console.log(`overwrite ${await overwrite()}`);
console.log(`nested ${await nested()}`);
console.log(`callee ${await callee()}`);
console.log(`set ${await sets()}`);
console.log(`module ${moduleSum} ${moduleIdle.size}`);
