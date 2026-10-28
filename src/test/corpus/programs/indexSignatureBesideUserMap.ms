// @stdout: string keys 1 2
// @stdout: int32 keys c
// @exit: 0
// note: an index signature is std's Map even where the module declares its own class named Map.

class Map<K, V> { tag: int32 = 1; }

const m: { [k: string]: int32 } = { a: 1, b: 2 };
console.log("string keys", m["a"], m.size);
const n: { [k: int32]: string } = {};
n.set(3, "c");
console.log("int32 keys", n.get(3) ?? "");
