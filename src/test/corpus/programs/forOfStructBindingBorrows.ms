// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: plain=0 sum=3 nested=4 pairs=3 local=0 len=6

struct Key { id: int32; tag: string; }

let copies: int32 = 0;
function onCopy(this ref dest: Key, src: Key): void { copies += 1; dest.id = src.id; dest.tag = src.tag; }

function idOf(k: Key): int32 { return k.id; }

function sum(keys: Key[]): int32 {
	let total: int32 = 0;
	for (const k of keys) total += idOf(k);
	return total;
}

function pairs(keys: Key[]): int32 {
	let n: int32 = 0;
	for (const a of keys) {
		for (const b of keys) {
			if (a.id <= b.id) n += 1;
		}
	}
	return n;
}

function local(): int32 {
	const keys: Key[] = [{ id: 1, tag: "ab" }, { id: 2, tag: "cd" }, { id: 3, tag: "ef" }];
	copies = 0;
	let len: int32 = 0;
	for (const k of keys) len += k.tag.length;
	return len;
}

const keys: Key[] = [{ id: 1, tag: "a" }, { id: 2, tag: "b" }];
copies = 0;
const total = sum(keys);
const plain = copies;
copies = 0;
const n = pairs(keys);
const nested = copies;
const len = local();
console.log(`plain=${plain} sum=${total} nested=${nested} pairs=${n} local=${copies} len=${len}`);
