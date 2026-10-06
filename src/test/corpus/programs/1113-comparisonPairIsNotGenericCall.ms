// Parity program — `b < x && a > (y)` is two comparisons: the tokens between
// the angles are not types, so the parser does not read a generic call there.
// Explicit type arguments before a call still bind.
//
// @stdout: false false true true 5 2 7 11 11 3 1
// @exit: 0

function id<T>(v: T): T { return v; }
class Box<T> { v: T; constructor(v: T) { this.v = v; } }

function both(a: int32, b: int32): boolean { return b < (0 as int32) && a > (5 as int32); }
function either(a: int32, b: int32, x: int32, y: int32): boolean { return b < x || a > (y); }

const p = both(1, -1);
const q = both(9, 1);
const r = both(9, -1);
const s = either(3, -1, 0, 5);

const f = (): int32 => 11;
const callbacks = id<(() => int32)[]>([f]);
const nested = new Box<((() => int32)[])[]>([callbacks]);
const values = id<(int32)[]>([3]);
const cleanups = new Map<int32, (() => void)[]>();
let calls: int32 = 0;
cleanups.set(1, [(): void => { calls++; }]);
for (const cleanup of cleanups.get(1) as (() => void)[]) { cleanup(); }
console.log(p, q, r, s, id<int32>(5), id<Array<int32>>([1, 2]).length, new Box<int32>(7).v, callbacks[0](), nested.v[0][0](), values[0], calls);
