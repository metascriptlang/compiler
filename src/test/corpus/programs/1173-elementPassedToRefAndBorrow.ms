// @stdout: 3 9 5 8 5 1
// @stdout: 77
// @stdout: 42

struct P { x: int32; }
struct S { items: P[]; bytes: uint8[]; }

function put(ref b: uint8, v: uint8): void { b = v; }
function setX(ref p: P, v: int32): void { p.x = v; }
function setN(ref n: int32): void { n = 42; }
function rd<T>(b: Borrow<T>): T { return b; }
function fill(data: Span<uint8>): void { put(data[1], 9); }

function main(): void {
let s: S = { items: [{ x: 1 }, { x: 2 }], bytes: [0, 0, 0] };
put(s.bytes[2], 5);
setX(s.items[1], 8);
const view: Span<uint8> = s.bytes;
put(view[0], 3);
fill(s.bytes);
console.log(s.bytes[0], s.bytes[1], s.bytes[2], s.items[1].x, rd(s.bytes[2]), rd(s.items[0]).x);
let grid: P[][] = [[{ x: 1 }], [{ x: 2 }, { x: 3 }]];
setX(grid[1][1], 77);
console.log(grid[1][1].x);
let nums: int32[][] = [[1, 2], [3, 4]];
setN(nums[1][0]);
console.log(nums[1][0]);
}
main();
