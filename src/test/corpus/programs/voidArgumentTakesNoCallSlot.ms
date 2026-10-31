// @stdout: 5 5 5 15 5 5 5 5

struct Box<T> { v: T; n: int32; }
function mk(): Box<void> { return { v: null, n: 3 }; }
function take<T>(x: T, n: int32): int32 { return n; }
function take2<T>(n: int32, x: T): int32 { return n; }
function take3<T>(a: int32, x: T, n: int32): int32 { return a * 10 + n; }
function plain(x: void, n: int32): int32 { return n; }
function vf(): void {}

const e = mk();
console.log([take(e.v, 5), take(mk().v, 5), take2(5, e.v), take3(1, e.v, 5), take(vf(), 5), take(undefined, 5), plain(e.v, 5), plain(vf(), 5)].join(" "));
