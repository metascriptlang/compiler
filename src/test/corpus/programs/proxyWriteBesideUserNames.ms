// @stdout: key 1020
// @stdout: proxy 25
// @stdout: method 1080
// @stdout: bytes 11
// note: a write or a handler method call through a Proxy whose receiver has effects reads the receiver and key once, and the author's own `$key` and `$proxy` keep their values inside it.
class Tr<T> {
	get<K extends keyof T>(t: T, k: K): T[K] { return Reflect.get(t, k); }
	set<K extends keyof T>(t: T, k: K, v: T[K]): boolean { return Reflect.set(t, k, v); }
	sum(t: int32[], extra: int32): int32 { let s = extra; for (const x of t) s += x; return s; }
}
const xs: int32[] = [10, 20, 30];
const p = new Proxy(xs, new Tr<int32[]>());
function getP(): Proxy<int32[], Tr<int32[]>> { return p; }
function mk(): int32 { return 1; }
const $key: int32 = 1000;
getP()[mk()] += $key;
console.log("key", xs[1]);
const $proxy = 5;
getP()[0] += $proxy + 10;
console.log("proxy", xs[0]);
console.log("method", getP().sum($proxy));
const bs: uint8[] = [10];
const q = new Proxy(bs, new Tr<uint8[]>());
function getQ(): Proxy<uint8[], Tr<uint8[]>> { return q; }
getQ()[0] += 1;
console.log("bytes", bs[0]);
