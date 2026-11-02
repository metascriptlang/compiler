// @stdout: bytes 6 spawned 6 string 6 item 6
// @serial
// note: Promise.all over Result<T, E> inputs destroys every payload with the result array: a byte array, a string and a class instance, completed inline and on pool threads.

class Item { v: int32 = 0; }

function work(i: int32): Result<uint8[], string> {
	const out: uint8[] = [];
	for (let k: int32 = 0; k <= i; k++) out.push(k as uint8);
	return Result.ok(out);
}
async function bytes(i: int32): Promise<Result<uint8[], string>> { return work(i); }
async function spawned(i: int32): Promise<Result<uint8[], string>> {
	return await spawn(() => { return work(i); });
}
async function text(i: int32): Promise<Result<string, string>> { return Result.ok(`value ${i}`); }
async function item(i: int32): Promise<Result<Item, string>> {
	const it = new Item();
	it.v = i;
	return Result.ok(it);
}

const a = await Promise.all([bytes(0), bytes(1), bytes(2), bytes(3), bytes(4), bytes(5)]);
const b = await Promise.all([spawned(0), spawned(1), spawned(2), spawned(3), spawned(4), spawned(5)]);
const c = await Promise.all([text(0), text(1), text(2), text(3), text(4), text(5)]);
const d = await Promise.all([item(0), item(1), item(2), item(3), item(4), item(5)]);
let na = 0;
let nb = 0;
let nc = 0;
let nd = 0;
for (const r of a) if (r.ok && r.value.length > 0) na += 1;
for (const r of b) if (r.ok && r.value.length > 0) nb += 1;
for (const r of c) if (r.ok && r.value.length > 0) nc += 1;
for (const r of d) if (r.ok && r.value.v >= 0) nd += 1;
console.log(`bytes ${na} spawned ${nb} string ${nc} item ${nd}`);
