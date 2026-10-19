// @stdout: 40 40 24 56 32
// @stdout: true 9 false 7
// @stdout: true 7 false 9
// @stdout: {"ok":false,"error":{"code":7}}
// @stdout: true 9|false 7|true 9
// @stdout: true north 4|false 5|true south 2
// @stdout: true 3 false far
// @stdout: {"ok":true,"text":"kept"} {"ok":true,"text":"kept"} {"ok":false,"code":3} kept {"ok":true} {"ok":true,"text":"kept","extra":1}
// @stdout: {"ok":true,"value":5} {"ok":true,"value":5}
// @stdout: true 3 false 4 {"ok":true,"n":3} {"ok":false,"n":4}
// @exit: 0

struct Key {
	bytes: uint8[32];
}

struct Failure {
	code: uint64;
}

struct Flag = match (ok: boolean) {
	true => { name: string, key: Key },
	false => { code: uint64 },
};

struct Hit {
	ok: true;
	at: uint8;
}

struct Miss {
	ok: false;
	why: string;
}

type Probe = Hit | Miss;

struct Word = match (ok: boolean) {
	true => { text: string },
	false => { code: int32 },
};

type Lone = { ok: true; n: int32 };
type Both = { ok: boolean; n: int32 };

function key(last: uint8): Key {
	let k: Key = { bytes: [] };
	k.bytes[31] = last;
	return k;
}

function pick(good: boolean): Result<Key, Failure> {
	if (!good) { return Result.err({ code: 7 }); }
	return Result.ok(key(9));
}

function pickReversed(good: boolean): Result<Failure, Key> {
	if (!good) { return Result.err(key(9)); }
	return Result.ok({ code: 7 });
}

function flag(good: boolean, name: string, last: uint8): Flag {
	if (!good) { return { ok: false, code: last as uint64 }; }
	return { ok: true, name: name, key: key(last) };
}

function word(good: boolean): Word {
	if (!good) { return { ok: false, code: 3 }; }
	return { ok: true, text: "kept" };
}

function count(good: boolean): Result<int32, string> {
	if (!good) { return Result.err("none"); }
	return Result.ok(5);
}

function show<T>(x: T): string {
	return JSON.stringify(x);
}

function describe(r: Result<Key, Failure>): string {
	if (r.ok) { return `true ${r.value.bytes[31]}`; }
	return `false ${r.error.code}`;
}

function describeFlag(f: Flag): string {
	if (f.ok) { return `true ${f.name} ${f.key.bytes[31]}`; }
	return `false ${f.code}`;
}

function probe(near: boolean): Probe {
	if (near) {
		const h: Hit = { ok: true, at: 3 };
		return h;
	}
	return { ok: false, why: "far" };
}

console.log(`${sizeof(Result<Key, Failure>)} ${sizeof(Result<Failure, Key>)} ${sizeof(Result<int32, string>)} ${sizeof(Flag)} ${sizeof(Probe)}`);

const good = pick(true);
const bad = pick(false);
if (good.ok && !bad.ok) {
	console.log(good.ok, good.value.bytes[31], bad.ok, bad.error.code);
}

const goodReversed = pickReversed(true);
const badReversed = pickReversed(false);
if (goodReversed.ok && !badReversed.ok) {
	console.log(goodReversed.ok, goodReversed.value.code, badReversed.ok, badReversed.error.bytes[31]);
}

console.log(JSON.stringify(bad));

const results: Result<Key, Failure>[] = [good, bad];
results.push(results[0]);
console.log(results.map((r) => describe(r)).join("|"));

const flags: Flag[] = [flag(true, "north", 4), flag(false, "", 5)];
let last = flag(true, "south", 2);
flags.push(last);
last = flags[0];
console.log(flags.map((f) => describeFlag(f)).join("|"));

const hit: Hit = { ok: true, at: 3 };
const near = probe(true);
const far = probe(false);
if (near.ok && !far.ok) {
	console.log(hit.ok, near.at, far.ok, far.why);
}

const w = word(true);
const v = word(false);
if (w.ok && !v.ok) {
	const { text, ...rest } = w;
	const wider = { ...w, extra: 1 };
	console.log(JSON.stringify(w), show(w), show(v), text, JSON.stringify(rest), JSON.stringify(wider));
}

const c = count(true);
if (c.ok) {
	console.log(JSON.stringify(c), show(c));
}

const lone: Lone = { ok: true, n: 3 };
const both: Both = { ok: false, n: 4 };
console.log(lone.ok, lone.n, both.ok, both.n, JSON.stringify(lone), JSON.stringify(both));
