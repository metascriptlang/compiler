// @stdout: try=3 field=4 maybe=5 grown=true,7,40
// @exit: 0

struct Pet { n: int32; }
struct Holder { ok: boolean; value: Pet; }
struct MaybeHolder { pet: Pet | null; }
struct Key { id: int32; }
export function `==`(x: Key, y: Key): boolean { return x.id == y.id; }
export function hash(this k: Key): int64 { return k.id as int64; }

function decode(seed: int32): Result<Pet, string> { return Result.ok({ n: seed }); }

function viaTry(seed: int32): Result<int32, string> {
	const v = try decode(seed);
	return Result.ok(v.n);
}

function viaField(seed: int32): int32 {
	const h: Holder = { ok: true, value: { n: seed } };
	const v = h.value;
	return v.n;
}

function viaMaybe(seed: int32): int32 {
	const h: MaybeHolder = { pet: { n: seed } };
	const v = h.pet;
	return v != null ? v.n : -1;
}

function grown(): string {
	const m = new HashMap<Key, int32>();
	for (let i: int32 = 0; i < 40; i += 1) {
		const k: Key = { id: i };
		m.set(k, i);
	}
	const seven: Key = { id: 7 };
	return `${m.has(seven)},${m.get(seven) ?? -1},${m.size}`;
}

const t = viaTry(3);
console.log(`try=${t.ok ? t.value : -1} field=${viaField(4)} maybe=${viaMaybe(5)} grown=${grown()}`);
