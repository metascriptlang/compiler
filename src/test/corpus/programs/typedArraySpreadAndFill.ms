// A typed array spreads into an array literal like an array, on every backend (Buffer, a subarray view, a Float32Array), and
// fill takes any number and stores it as the element type converts it (ToUint8, ToInt8, ... ; NaN to 0), as Node does.
// @stdout: 5 0 1 3 9
// @stdout: 2 2 3
// @stdout: 3 1.5 2
// @stdout: 2
// @stdout: 255
// @stdout: 3
// @stdout: 44
// @stdout: -56
// @stdout: -25536
// @stdout: 4294967295
// @stdout: -1294967296
// @stdout: 0

const b = Buffer.from([1, 2, 3]);
const xs: uint8[] = [0, ...b, 9];
console.log(xs.length, xs[0], xs[1], xs[3], xs[4]);
const sub = b.subarray(1, 3);
const ys: uint8[] = [...sub];
console.log(ys.length, ys[0], ys[1]);
const f = new Float32Array(2);
f[0] = 1.5;
const zs: float32[] = [...f, 2];
console.log(zs.length, zs[0], zs[2]);
const u = new Uint8Array(4);
u.fill(258);
console.log(u[0]);
u.fill(-1, 1);
console.log(u[1]);
u.fill(3.9, 2, 3);
console.log(u[2]);
const n: int32 = 300;
u.fill(n, 3);
console.log(u[3]);
const i8 = new Int8Array(2);
i8.fill(200);
console.log(i8[0]);
const i16 = new Int16Array(1);
i16.fill(40000);
console.log(i16[0]);
const u32 = new Uint32Array(1);
u32.fill(-1);
console.log(u32[0]);
const i32 = new Int32Array(1);
i32.fill(3000000000);
console.log(i32[0]);
const g = new Uint8Array(1);
g.fill(NaN);
console.log(g[0]);
