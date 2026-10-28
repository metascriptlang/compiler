// The legal neighbour of spawnStaticFieldRejects.ms: a spawn thunk reads a `static readonly` field of
// a scalar type, as it reads a module const, and reads its own copy of a mutable static taken before
// the spawn.
//
// GUARD-JS
class C {
	static readonly LIMIT: int32 = 40;
	static n: int32 = 2;
}

const copy = C.n;
const r = spawn((): int32 => C.LIMIT + copy);
const v = await r;
if (v != 42) throw new Error(`GUARD-FAIL ${v}`);
console.log("GUARD-OK");
