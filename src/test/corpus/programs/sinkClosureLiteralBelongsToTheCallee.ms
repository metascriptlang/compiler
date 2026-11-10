// @stdout: start
// @stdout: field 1 6
// @stdout: captured 1 42
// @stdout: generic 1 8 deferred=2
// @stdout: packed 1 1 52
// @stdout: skipped 3
// @stdout: map 2 11 22
// @stdout: skipped 4
// @stdout: hashMap 2 33 44
struct Ent { k: int64; v: () => int32; }
struct At { x: int32; y: int32; }

function put(a: Ent[], sink v: () => int32): void {
	if (a.length > 0) {
		a[0].v = v;
		return;
	}
	a.push({ k: 1, v: v });
}

function putAt(a: Ent[], at: At, sink v: () => int32): void {
	if (a.length > 0) {
		a[0].v = v;
		return;
	}
	a.push({ k: at.x, v: v });
}

function putLast<T>(a: T[], sink v: T, log: string[]): void {
	defer { log.push("d"); }
	if (a.length > 0) {
		a[0] = v;
		return;
	}
	a.push(v);
}

function remember(m: Map<int64, () => int32>, k: int64, sink f: () => int32): void {
	if (k > 0) {
		m.set(k, f);
		return;
	}
	console.log("skipped", f().toString());
}

function rememberHashed(m: HashMap<int64, () => int32>, k: int64, sink f: () => int32): void {
	if (k > 0) {
		m.set(k, f);
		return;
	}
	console.log("skipped", f().toString());
}

function fill(a: Ent[], base: int32): void {
	put(a, (): int32 => base + 1);
	put(a, (): int32 => base + 2);
}

function fillAt(a: Ent[], base: int32): void {
	putAt(a, { x: 1, y: 2 }, (): int32 => base + 1);
	putAt(a, { x: 3, y: 4 }, (): int32 => base + 2);
}

function fillHashed(m: HashMap<int64, () => int32>, base: int32): void {
	rememberHashed(m, 1, (): int32 => base - 7);
	rememberHashed(m, 2, (): int32 => base + 4);
	rememberHashed(m, 0, (): int32 => base - 36);
}

console.log("start");

const fields: Ent[] = [];
put(fields, (): int32 => 5);
put(fields, (): int32 => 6);
console.log("field", fields.length, fields[0].v().toString());

const captured: Ent[] = [];
fill(captured, 40);
console.log("captured", captured.length, captured[0].v().toString());

const log: string[] = [];
const generic: (() => int32)[] = [];
putLast(generic, (): int32 => 7, log);
putLast(generic, (): int32 => 8, log);
console.log("generic", generic.length, generic[0]().toString(), `deferred=${log.length}`);

const packed: Ent[] = [];
fillAt(packed, 50);
console.log("packed", packed.length, packed[0].k, packed[0].v().toString());

const map = new Map<int64, () => int32>();
remember(map, 1, (): int32 => 11);
remember(map, 2, (): int32 => 22);
remember(map, 0, (): int32 => 3);
console.log("map", map.size, map.get(1)!().toString(), map.get(2)!().toString());

const hashed = new HashMap<int64, () => int32>();
fillHashed(hashed, 40);
console.log("hashMap", hashed.size, hashed.get(1)!().toString(), hashed.get(2)!().toString());
