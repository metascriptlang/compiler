// Parity program — a key type's own `==` and `hash` reach a generic body declared in another
// module, the std Map, Set and HashMap included: an equal key is found, overwrites and is not
// added twice. Flat and receiver-form `==`, each with a hash that agrees with it.
//
// @stdout: direct=true,true genLib=true,true map=true,1,y set=1,true hashmap=true,1 recv=true,1
// @exit: 0

import { sameX } from "./lib/generic";

struct K { a: int32; b: int32; }
export function `==`(x: K, y: K): boolean { return x.a == y.a; }
export function hash(this k: K): int64 { return k.a as int64; }

struct R { a: int32; b: int32; }
export function `==`(this x: R, y: R): boolean { return x.a == y.a; }
export function hash(this r: R): int64 { return r.a as int64; }

const k1: K = { a: 1, b: 1 };
const k2: K = { a: 1, b: 2 };
const r1: R = { a: 1, b: 1 };
const r2: R = { a: 1, b: 2 };

const m = new Map<K, string>();
m.set(k1, "x");
const mapHas = m.has(k2);
m.set(k2, "y");
const s = new Set<K>();
s.add(k1);
s.add(k2);
const hm = new HashMap<K, int32>();
hm.set(k1, 1);
const hmHas = hm.has(k2);
hm.set(k2, 2);
const mr = new Map<R, int32>();
mr.set(r1, 1);
const mrHas = mr.has(r2);
mr.set(r2, 2);

console.log("direct=" + (k1 == k2) + "," + (r1 == r2)
	+ " genLib=" + sameX(k1, k2) + "," + sameX(r1, r2)
	+ " map=" + mapHas + "," + m.size + "," + (m.get(k1) ?? "none")
	+ " set=" + s.size + "," + s.has(k2)
	+ " hashmap=" + hmHas + "," + hm.size
	+ " recv=" + mrHas + "," + mr.size);
