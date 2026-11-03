// @stdout: top k=1 cursor=5 own=6 true true
// @stdout: one k=2 cursor=7 own=6 true true
// @stdout: twice k=3 cursor=7 own=8 true true
// @stdout: twice k=3 cursor=7 own=8 true true
// @stdout: all k=4 cursor=9 own=8 true true
// @stdout: all k=5 cursor=9 own=8 true true
// @stdout: end
// note: a struct that holds a class instance and a cursor to one, read out of a future, still names those instances: a sole await at the top level and in an async function, a promise awaited twice and Promise.all of two each share the class objects instead of copying them, and nothing they share is left behind.

class T { n: int32 = 0; }
struct S { c: Cursor<T>; own: T; k: int32; }

const t = new T();
const u = new T();

async function tick(): Promise<void> { await sleepAsync(0); }
async function make(k: int32): Promise<S> { return { c: t, own: u, k: k }; }
async function later(k: int32): Promise<S> { const s: S = { c: t, own: u, k: k }; await tick(); return s; }

function same(tag: string, s: S): void {
	console.log(`${tag} k=${s.k} cursor=${s.c.n} own=${s.own.n} ${s.c === t} ${s.own === u}`);
}

const top = await make(1);
t.n = 5;
u.n = 6;
same("top", top);

async function run(): Promise<void> {
	const a = await later(2);
	t.n = 7;
	same("one", a);
	const p = later(3);
	const b1 = await p;
	const b2 = await p;
	u.n = 8;
	same("twice", b1);
	same("twice", b2);
	const both = await Promise.all([make(4), later(5)]);
	t.n = 9;
	same("all", both[0]);
	same("all", both[1]);
}
await run();
console.log("end");
